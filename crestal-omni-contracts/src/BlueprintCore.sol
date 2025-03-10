// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {EIP712} from "./EIP712.sol";
import {Payment} from "./Payment.sol";

contract BlueprintCore is EIP712, Payment {
    enum Status {
        Init,
        Issued,
        Pickup,
        Deploying,
        Deployed,
        GeneratedProof
    }

    struct DeploymentStatus {
        Status status;
        address deployWorkerAddr;
    }

    // slither-disable-next-line naming-convention
    string public VERSION;
    // This is considered initialized due to BlueprintV1 deployment, however
    // for future upgrades, it can be seen as "uninitialized" but we should
    // not override it again in upgrades unless absolutely necessary
    // slither-disable-next-line uninitialized-state,constable-states
    uint256 public factor;
    uint256 public totalProposalRequest;
    uint256 public totalDeploymentRequest;

    mapping(address => bytes32) public latestProposalRequestID;
    mapping(address => bytes32) public latestDeploymentRequestID;
    mapping(address => bytes32) public latestProjectID;

    mapping(address => uint256) public solverReputation;
    mapping(address => uint256) public workerReputation;
    mapping(bytes32 => DeploymentStatus) public requestDeploymentStatus;

    mapping(bytes32 => string) private deploymentProof;
    mapping(bytes32 => address) private requestSolver;
    mapping(bytes32 => address) private requestWorker;
    // projectIDs is not used anymore after 2.0
    mapping(bytes32 => address) private projectIDs;

    // keep old variable in order so that it can be compatible with old contract

    // new variable and struct
    struct Project {
        bytes32 id;
        bytes32 requestProposalID;
        bytes32 requestDeploymentID;
        address proposedSolverAddr;
    }

    address public constant dummyAddress = address(0);

    // project map
    mapping(bytes32 => Project) private projects;

    mapping(bytes32 => bytes32[]) public deploymentIdList;

    // List of worker addresses
    address[] private workerAddresses;
    // worker public key
    mapping(address => bytes) private workersPublicKey;

    // worker address mapping
    mapping(string => address[]) private workerAddressesMp;

    string private constant WORKER_ADDRESS_KEY = "worker_address_key";

    // NFT token id mapping, one NFT token id can only be used once
    mapping(uint256 => Status) public nftTokenIdMap;

    address public nftContractAddress;

    // whitelist user can create an agent
    mapping(address => Status) public whitelistUsers;

    // deployment owner
    mapping(bytes32 => address) private deploymentOwners;

    // payment related variables
    string public constant PAYMENT_KEY = "payment_key";

    string public constant CREATE_AGENT_OP = "create_agent";
    string public constant UPDATE_AGENT_OP = "update_agent";

    address public feeCollectionWalletAddress;

    mapping(string => address[]) public paymentAddressesMp;

    mapping(address => bool) public paymentAddressEnableMp;

    mapping(address => mapping(string => uint256)) public paymentOpCostMp;

    mapping(address => mapping(address => uint256)) public userTopUpMp;

    event CreateProjectID(bytes32 indexed projectID, address walletAddress);
    event RequestProposal(
        bytes32 indexed projectID,
        address walletAddress,
        bytes32 indexed requestID,
        string base64RecParam,
        string serverURL
    );
    event RequestPrivateProposal(
        bytes32 indexed projectID,
        address walletAddress,
        address privateSolverAddress,
        bytes32 indexed requestID,
        string base64RecParam,
        string serverURL
    );
    event RequestDeployment(
        bytes32 indexed projectID,
        address walletAddress,
        address solverAddress,
        bytes32 indexed requestID,
        string base64Proposal,
        string serverURL
    );
    event RequestPrivateDeployment(
        bytes32 indexed projectID,
        address walletAddress,
        address privateWorkerAddress,
        address solverAddress,
        bytes32 indexed requestID,
        string base64Proposal,
        string serverURL
    );
    event AcceptDeployment(bytes32 indexed projectID, bytes32 indexed requestID, address indexed workerAddress);
    event GeneratedProofOfDeployment(
        bytes32 indexed projectID, bytes32 indexed requestID, string base64DeploymentProof
    );

    event UpdateDeploymentConfig(
        bytes32 indexed projectID, bytes32 indexed requestID, address workerAddress, string base64Config
    );

    event CreateAgent(
        bytes32 indexed projectID, bytes32 indexed requestID, address walletAddress, uint256 nftTokenId, uint256 amount
    );

    event UserTopUp(
        address indexed walletAddress, address feeCollectionWalletAddress, address tokenAddress, uint256 amount
    );

    modifier newProject(bytes32 projectId) {
        // check project id
        // slither-disable-next-line incorrect-equality,timestamp
        require(projects[projectId].id == 0, "projectId already exists");
        _;
    }

    modifier hasProjectNew(bytes32 projectId) {
        // only new upgraded (v2) blueprint uses this function
        // slither-disable-next-line timestamp
        require(projects[projectId].id != 0, "projectId does not exist");
        _;
    }

    modifier hasProject(bytes32 projectId) {
        // projectId backwards compatibility
        //    projects[projectId].id != 0 --> false --> new project id created by new blueprint not exist
        //    projectIDs[projectId] != address(0) -- > false -- >. old project id created by old blueprint not exist.
        //    both 1 and 2 are false, then project id does not exist in old and new blueprint
        // slither-disable-next-line timestamp
        require(projects[projectId].id != 0 || projectIDs[projectId] != dummyAddress, "projectId does not exist");
        _;
    }

    function setProjectId(bytes32 projectId, address userAddr) internal newProject(projectId) {
        require(userAddr != dummyAddress, "Invalid userAddr");

        Project memory project =
            Project({id: projectId, requestProposalID: 0, requestDeploymentID: 0, proposedSolverAddr: dummyAddress});
        // set project info into mapping
        projects[projectId] = project;

        // set latest project
        latestProjectID[userAddr] = projectId;

        emit CreateProjectID(projectId, userAddr);
    }

    function createProjectID() public returns (bytes32 projectId) {
        // generate unique project id
        // FIXME: typically we shouldn't just use block.timestamp, as this prevents multi-project
        // creation during a single block - which shouldn't be impossible...
        projectId = keccak256(abi.encodePacked(block.timestamp, msg.sender, block.chainid));

        setProjectId(projectId, msg.sender);
    }

    function upgradeProject(bytes32 projectId) public hasProject(projectId) {
        // reset project info
        projects[projectId].requestProposalID = 0;
        projects[projectId].requestDeploymentID = 0;
        projects[projectId].proposedSolverAddr = dummyAddress;
    }

    function proposalRequest(
        address userAddress,
        bytes32 projectId,
        address solverAddress,
        string memory base64RecParam,
        string memory serverURL
    ) internal hasProject(projectId) returns (bytes32 requestID) {
        require(bytes(serverURL).length > 0, "serverURL is empty");
        require(bytes(base64RecParam).length > 0, "base64RecParam is empty");

        // generate unique hash
        requestID = keccak256(abi.encodePacked(block.timestamp, userAddress, base64RecParam, block.chainid));

        // check request id is created or not
        // if it is created, then we need to lock it, not allow user to trigger proposal request again
        // slither-disable-next-line incorrect-equality,timestamp
        require(projects[projectId].requestProposalID == 0, "proposal requestID already exists");

        // FIXME: This prevents a msg.sender to create multiple requests at the same time?
        // For different projects, a solver is allowed to create one (latest proposal) for each.
        latestProposalRequestID[userAddress] = requestID;

        projects[projectId].requestProposalID = requestID;

        totalProposalRequest++;

        // set request id associated private solver
        if (solverAddress != dummyAddress) {
            // private proposal request
            requestSolver[requestID] = solverAddress;
        }
    }

    function createCommonProposalRequest(
        address userAddress,
        bytes32 projectId,
        string memory base64RecParam,
        string memory serverURL
    ) internal returns (bytes32 requestID) {
        requestID = proposalRequest(userAddress, projectId, dummyAddress, base64RecParam, serverURL);

        emit RequestProposal(projectId, userAddress, requestID, base64RecParam, serverURL);
    }

    // issue createProposalRequest
    // `base64RecParam` should be an encoded base64 ChainRequestParam json string
    // https://github.com/crestalnetwork/crestal-dashboard-backend/blob/testnet-dev/listen/type.go#L9
    // example: {"type":"DA","latency":5,"max_throughput":20,"finality_time":10,"block_time":5,"created_at":"0001-01-01T00:00:00Z"}
    // associated base64 string: eyJ0eXBlIjoiREEiLCJsYXRlbmN5Ijo1LCJtYXhfdGhyb3VnaHB1dCI6MjAsImZpbmFsaXR5X3RpbWUiOjEwLCJibG9ja190aW1lIjo1LCJjcmVhdGVkX2F0IjoiMDAwMS0wMS0wMVQwMDowMDowMFoifQ

    function createProjectIDAndProposalRequest(bytes32 projectId, string memory base64RecParam, string memory serverURL)
        public
        returns (bytes32 requestID)
    {
        // set project id
        setProjectId(projectId, msg.sender);
        // create proposal request
        requestID = createCommonProposalRequest(msg.sender, projectId, base64RecParam, serverURL);
    }

    function createProjectIDAndProposalRequestWithSig(
        bytes32 projectId,
        string memory base64RecParam,
        string memory serverURL,
        bytes memory signature
    ) public returns (bytes32 requestID) {
        // get EIP712 hash digest
        bytes32 digest = getRequestProposalDigest(projectId, base64RecParam, serverURL);

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        // set project id
        setProjectId(projectId, signerAddr);
        // create proposal request
        requestID = createCommonProposalRequest(signerAddr, projectId, base64RecParam, serverURL);
    }

    function deploymentRequest(
        address userAddress,
        bytes32 projectId,
        address solverAddress,
        address workerAddress,
        string memory base64Proposal,
        string memory serverURL,
        uint256 index
    ) internal hasProject(projectId) returns (bytes32 requestID, bytes32 projectDeploymentId) {
        require(bytes(serverURL).length > 0, "serverURL is empty");
        require(bytes(base64Proposal).length > 0, "base64Proposal is empty");

        // generate project used deployment id that linked to many deploymentsID associated with different service id
        projectDeploymentId =
            keccak256(abi.encodePacked(block.timestamp, userAddress, base64Proposal, block.chainid, projectId));

        // check projectDeploymentId id is created or not
        // if it is created, which means project has started deployment process, should lock
        // slither-disable-next-line incorrect-equality,timestamp
        require(projects[projectId].requestDeploymentID == 0, "deployment requestID already exists");

        // generate unique deployment requestID message hash
        requestID =
            keccak256(abi.encodePacked(block.timestamp, userAddress, base64Proposal, block.chainid, projectId, index));

        latestDeploymentRequestID[userAddress] = requestID;

        // workerAddress == address(0): init deployment status, not picked by any worker
        // workerAddress != address(0):
        // private deployment request
        // set pick up deployment status since this is private deployment request,
        // which can be picked only by designated worker
        DeploymentStatus memory deploymentStatus = DeploymentStatus({
            status: (workerAddress == dummyAddress ? Status.Issued : Status.Pickup),
            deployWorkerAddr: workerAddress
        });

        requestDeploymentStatus[requestID] = deploymentStatus;

        // update project solver info
        projects[projectId].proposedSolverAddr = solverAddress;
    }

    function createCommonDeploymentRequest(
        address userAddress,
        bytes32 projectId,
        address solverAddress,
        address workerAddress,
        string memory base64Proposal,
        string memory serverURL
    ) internal returns (bytes32 requestID) {
        require(solverAddress != dummyAddress, "solverAddress is not valid");

        bytes32 projectDeploymentId;
        (requestID, projectDeploymentId) =
            deploymentRequest(userAddress, projectId, solverAddress, workerAddress, base64Proposal, serverURL, 0);
        totalDeploymentRequest++;

        // once we got request deploymentID, then we set project requestDeploymentID, which points to a list of deploymentID
        projects[projectId].requestDeploymentID = projectDeploymentId;

        // push request deploymentID into map, link to a project
        deploymentIdList[projectDeploymentId].push(requestID);

        if (workerAddress == dummyAddress) {
            emit RequestDeployment(projectId, userAddress, solverAddress, requestID, base64Proposal, serverURL);
        } else {
            emit RequestPrivateDeployment(
                projectId, userAddress, workerAddress, solverAddress, requestID, base64Proposal, serverURL
            );

            // emit accept deployment event since this deployment request is accepted by blueprint
            emit AcceptDeployment(projectId, requestID, workerAddress);
        }
    }

    function createCommonProjectIDAndDeploymentRequest(
        address userAddress,
        bytes32 projectId,
        string memory base64Proposal,
        address workerAddress,
        string memory serverURL
    ) internal returns (bytes32 requestID) {
        // set project id
        setProjectId(projectId, userAddress);

        // create deployment request without solver recommendation, so leave solver address as dummyAddress
        // since this is public deployment request leave worker address as dummyAddress
        bytes32 projectDeploymentId;
        (requestID, projectDeploymentId) =
            deploymentRequest(userAddress, projectId, dummyAddress, workerAddress, base64Proposal, serverURL, 0);
        totalDeploymentRequest++;

        projects[projectId].requestDeploymentID = projectDeploymentId;

        deploymentIdList[projectDeploymentId].push(requestID);

        if (workerAddress == dummyAddress) {
            emit RequestDeployment(projectId, userAddress, dummyAddress, requestID, base64Proposal, serverURL);
        } else {
            emit RequestPrivateDeployment(
                projectId, userAddress, workerAddress, dummyAddress, requestID, base64Proposal, serverURL
            );
            // emit accept deployment event since this deployment request is accepted by blueprint
            emit AcceptDeployment(projectId, requestID, workerAddress);
        }
    }

    function createProjectIDAndDeploymentRequest(
        bytes32 projectId,
        string memory base64Proposal,
        string memory serverURL
    ) public returns (bytes32 requestID) {
        requestID =
            createCommonProjectIDAndDeploymentRequest(msg.sender, projectId, base64Proposal, dummyAddress, serverURL);
    }

    function createProjectIDAndDeploymentRequestWithSig(
        bytes32 projectId,
        string memory base64Proposal,
        string memory serverURL,
        bytes memory signature
    ) public returns (bytes32 requestID) {
        // get EIP712 hash digest
        bytes32 digest = getRequestDeploymentDigest(projectId, base64Proposal, serverURL);

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        requestID =
            createCommonProjectIDAndDeploymentRequest(signerAddr, projectId, base64Proposal, dummyAddress, serverURL);
    }

    function createProjectIDAndPrivateDeploymentRequest(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL
    ) public returns (bytes32 requestID) {
        requestID = createCommonProjectIDAndDeploymentRequest(
            msg.sender, projectId, base64Proposal, privateWorkerAddress, serverURL
        );
    }

    function createAgent(
        address userAddress,
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        uint256 tokenId,
        address tokenAddress
    ) internal returns (bytes32 requestID) {
        if (tokenAddress == address(0)) {
            // create agent with nft
            // check NFT token id is already used or not
            require(nftTokenIdMap[tokenId] != Status.Pickup, "NFT token id already used");

            // check NFT ownership
            require(checkNFTOwnership(nftContractAddress, tokenId, userAddress), "NFT token not owned by user");

            requestID = createCommonProjectIDAndDeploymentRequest(
                userAddress, projectId, base64Proposal, privateWorkerAddress, serverURL
            );

            // update NFT token id status
            nftTokenIdMap[tokenId] = Status.Pickup;

            // set deployment owner
            deploymentOwners[requestID] = userAddress;

            // emit create agent event
            emit CreateAgent(projectId, requestID, userAddress, tokenId, 0);
        } else {
            // create agent with token
            // check token address is valid and in paymentOpCostMp
            require(paymentAddressEnableMp[tokenAddress], "Token address is invalid");
            // get cost of create agent operation
            uint256 cost = paymentOpCostMp[tokenAddress][CREATE_AGENT_OP];
            if (cost > 0) {
                // payment to crestal wallet address with token
                payWithERC20(tokenAddress, cost, userAddress, feeCollectionWalletAddress);
            }

            requestID = createCommonProjectIDAndDeploymentRequest(
                userAddress, projectId, base64Proposal, privateWorkerAddress, serverURL
            );

            // set deployment owner
            deploymentOwners[requestID] = userAddress;

            // emit create agent event
            emit CreateAgent(projectId, requestID, userAddress, tokenId, cost);
        }
    }

    function createAgentWithToken(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        address tokenAddress
    ) public returns (bytes32 requestID) {
        require(tokenAddress != address(0), "Token address is empty");

        requestID = createAgent(msg.sender, projectId, base64Proposal, privateWorkerAddress, serverURL, 0, tokenAddress);
    }

    function createAgentWithTokenWithSig(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        address tokenAddress,
        bytes memory signature
    ) public returns (bytes32 requestID) {
        require(tokenAddress != address(0), "Token address is empty");

        // get EIP712 hash digest
        bytes32 digest = getRequestDeploymentDigest(projectId, base64Proposal, serverURL);

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        requestID = createAgent(signerAddr, projectId, base64Proposal, privateWorkerAddress, serverURL, 0, tokenAddress);
    }

    function createAgentWithNFT(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        uint256 tokenId
    ) public returns (bytes32 requestID) {
        requestID =
            createAgent(msg.sender, projectId, base64Proposal, privateWorkerAddress, serverURL, tokenId, address(0));
    }

    function createAgentWithWhitelistUsers(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        uint256 tokenId
    ) public returns (bytes32 requestID) {
        // check whitelist user
        require(whitelistUsers[msg.sender] != Status.Init, "User is not in whitelist");

        // one whitelist user can only create one agent
        require(whitelistUsers[msg.sender] != Status.Pickup, "User already created agent");

        requestID =
            createAgent(msg.sender, projectId, base64Proposal, privateWorkerAddress, serverURL, tokenId, address(0));

        whitelistUsers[msg.sender] = Status.Pickup;
    }

    function createAgentWithWhitelistUsersWithSig(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        uint256 tokenId,
        bytes memory signature
    ) public returns (bytes32 requestID) {
        // get EIP712 hash digest
        bytes32 digest = getRequestDeploymentDigest(projectId, base64Proposal, serverURL);

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        // check whitelist user
        require(whitelistUsers[signerAddr] != Status.Init, "User is not in whitelist");

        // one whitelist user can only create one agent
        require(whitelistUsers[signerAddr] != Status.Pickup, "User already created agent");

        requestID =
            createAgent(signerAddr, projectId, base64Proposal, privateWorkerAddress, serverURL, tokenId, address(0));

        whitelistUsers[signerAddr] = Status.Pickup;
    }

    function createAgentWithSigWithNFT(
        bytes32 projectId,
        string memory base64Proposal,
        address privateWorkerAddress,
        string memory serverURL,
        bytes memory signature,
        uint256 tokenId
    ) public returns (bytes32 requestID) {
        // get EIP712 hash digest
        bytes32 digest = getRequestDeploymentDigest(projectId, base64Proposal, serverURL);

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        requestID =
            createAgent(signerAddr, projectId, base64Proposal, privateWorkerAddress, serverURL, tokenId, address(0));
    }

    function submitProofOfDeployment(bytes32 projectId, bytes32 requestID, string memory proofBase64)
        public
        hasProject(projectId)
    {
        require(requestID.length > 0, "requestID is empty");
        require(requestDeploymentStatus[requestID].status != Status.Init, "requestID does not exist");
        require(requestDeploymentStatus[requestID].deployWorkerAddr == msg.sender, "Wrong worker address");
        require(requestDeploymentStatus[requestID].status != Status.GeneratedProof, "Already submitted proof");

        // set deployment status into generatedProof
        requestDeploymentStatus[requestID].status = Status.GeneratedProof;

        // save deployment proof to mapping
        deploymentProof[requestID] = proofBase64;

        emit GeneratedProofOfDeployment(projectId, requestID, proofBase64);
    }

    function submitDeploymentRequest(bytes32 projectId, bytes32 requestID)
        public
        hasProject(projectId)
        returns (bool isAccepted)
    {
        require(requestID.length > 0, "requestID is empty");
        require(requestDeploymentStatus[requestID].status != Status.Init, "requestID does not exist");
        require(
            requestDeploymentStatus[requestID].status != Status.Pickup,
            "requestID already picked by another worker, try a different requestID"
        );

        require(
            requestDeploymentStatus[requestID].status != Status.GeneratedProof, "requestID has already submitted proof"
        );

        // currently, do first come, first server, will do a better way in the future
        requestDeploymentStatus[requestID].status = Status.Pickup;
        requestDeploymentStatus[requestID].deployWorkerAddr = msg.sender;

        // set project deployed worker address
        isAccepted = true;

        emit AcceptDeployment(projectId, requestID, requestDeploymentStatus[requestID].deployWorkerAddr);
    }

    function updateWorkerDeploymentConfigCommon(
        address tokenAddress,
        address userAddress,
        bytes32 projectId,
        bytes32 requestID,
        string memory updatedBase64Config
    ) internal hasProject(projectId) {
        require(requestDeploymentStatus[requestID].status != Status.Init, "requestID does not exist");
        require(bytes(updatedBase64Config).length > 0, "updatedBase64Config is empty");
        require(requestDeploymentStatus[requestID].status != Status.Issued, "requestID is not picked up by any worker");

        // check if it owner of requestID
        require(deploymentOwners[requestID] == userAddress, "Only deployment owner can update config");

        // check tokenAddress is valid and must be in paymentOpCostMp
        require(paymentAddressEnableMp[tokenAddress], "Invalid token address");

        // get update agent cost
        uint256 cost = paymentOpCostMp[tokenAddress][UPDATE_AGENT_OP];

        if (cost > 0) {
            // transfer token to crestal wallet
            payWithERC20(tokenAddress, cost, userAddress, feeCollectionWalletAddress);
        }

        // reset status if it is generated proof
        if (requestDeploymentStatus[requestID].status == Status.GeneratedProof) {
            requestDeploymentStatus[requestID].status = Status.Pickup;
        }

        emit UpdateDeploymentConfig(
            projectId, requestID, requestDeploymentStatus[requestID].deployWorkerAddr, updatedBase64Config
        );
    }

    function updateWorkerDeploymentConfig(
        address tokenAddress,
        bytes32 projectId,
        bytes32 requestID,
        string memory updatedBase64Config
    ) public {
        updateWorkerDeploymentConfigCommon(tokenAddress, msg.sender, projectId, requestID, updatedBase64Config);
    }

    function updateWorkerDeploymentConfigWithSig(
        address tokenAddress,
        bytes32 projectId,
        bytes32 requestID,
        string memory updatedBase64Config,
        bytes memory signature
    ) public {
        // get EIP712 hash digest
        bytes32 digest = getRequestDeploymentDigest(projectId, updatedBase64Config, "app.crestal.network");

        // get signer address
        address signerAddr = getSignerAddress(digest, signature);

        updateWorkerDeploymentConfigCommon(tokenAddress, signerAddr, projectId, requestID, updatedBase64Config);
    }

    // set worker public key
    function setWorkerPublicKey(bytes calldata publicKey) public {
        if (workersPublicKey[msg.sender].length == 0) {
            workerAddressesMp[WORKER_ADDRESS_KEY].push(msg.sender);
        }

        workersPublicKey[msg.sender] = publicKey;
    }

    // get worker public key
    function getWorkerPublicKey(address workerAddress) external view returns (bytes memory publicKey) {
        publicKey = workersPublicKey[workerAddress];
    }

    // get list of worker addresses
    function getWorkerAddresses() public view returns (address[] memory) {
        return workerAddressesMp[WORKER_ADDRESS_KEY];
    }

    // get list of payment addresses
    function getPaymentAddresses() public view returns (address[] memory) {
        return paymentAddressesMp[PAYMENT_KEY];
    }

    // get latest proposal request id
    function getLatestProposalRequestID(address addr) public view returns (bytes32) {
        return latestProposalRequestID[addr];
    }

    // get latest deployment request id
    function getLatestDeploymentRequestID(address addr) public view returns (bytes32) {
        return latestDeploymentRequestID[addr];
    }

    // get latest project id of user
    function getLatestUserProjectID(address addr) public view returns (bytes32) {
        return latestProjectID[addr];
    }

    // get project info
    function getProjectInfo(bytes32 projectId)
        public
        view
        hasProjectNew(projectId)
        returns (address, bytes32, bytes32[] memory)
    {
        bytes32[] memory requestDeploymentIDs = deploymentIdList[projects[projectId].requestDeploymentID];

        return (projects[projectId].proposedSolverAddr, projects[projectId].requestProposalID, requestDeploymentIDs);
    }

    function getDeploymentProof(bytes32 requestID) public view returns (string memory) {
        return deploymentProof[requestID];
    }

    function getEIP712ContractAddress() public view returns (address) {
        return getAddress();
    }

    function isWhitelistUser(address userAddress) public view returns (bool) {
        return whitelistUsers[userAddress] == Status.Issued || whitelistUsers[userAddress] == Status.Pickup;
    }

    function userTopUp(address tokenAddress, uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");

        require(paymentAddressEnableMp[tokenAddress], "Payment address is not valid");

        payWithERC20(tokenAddress, amount, msg.sender, feeCollectionWalletAddress);

        // update user top up
        userTopUpMp[msg.sender][tokenAddress] += amount;

        emit UserTopUp(msg.sender, feeCollectionWalletAddress, tokenAddress, amount);
    }
}
