// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./BlueprintCore.sol";

contract Blueprint is OwnableUpgradeable, BlueprintCore {
    event PaymentAddressAdded(address paymentAddress);
    event CreateAgentTokenCost(address paymentAddress, uint256 cost);
    event UpdateAgentTokenCost(address paymentAddress, uint256 cost);
    event RemovePaymentAddress(address paymentAddress);
    event FeeCollectionWalletAddress(address feeCollectionWalletAddress);

    // slither-disable-next-line naming-convention
    function setNFTContractAddress(address _nftContractAddress) public onlyOwner {
        require(_nftContractAddress != address(0), "NFT Contract is invalid");
        nftContractAddress = _nftContractAddress;
    }

    function setWhitelistAddresses(address[] calldata whitelistAddress) public onlyOwner {
        for (uint256 i = 0; i < whitelistAddress.length; i++) {
            whitelistUsers[whitelistAddress[i]] = Status.Issued;
        }
    }

    function addWhitelistAddress(address whitelistAddress) public onlyOwner {
        whitelistUsers[whitelistAddress] = Status.Issued;
    }

    function deleteWhitelistAddress(address whitelistAddress) public onlyOwner {
        delete whitelistUsers[whitelistAddress];
    }

    function resetAgentCreationStatus(address userAddress, uint256 tokenId) public onlyOwner {
        whitelistUsers[userAddress] = Status.Issued;
        nftTokenIdMap[tokenId] = Status.Init;
    }

    // slither-disable-next-line costly-loop
    function removeWhitelistAddresses(address[] calldata removedAddress) public onlyOwner {
        for (uint256 i = 0; i < removedAddress.length; i++) {
            delete whitelistUsers[removedAddress[i]];
        }
    }

    function addPaymentAddress(address paymentAddress) public onlyOwner {
        require(paymentAddress != address(0), "Payment Address is invalid");
        paymentAddressesMp[PAYMENT_KEY].push(paymentAddress);
        paymentAddressEnableMp[paymentAddress] = true;

        emit PaymentAddressAdded(paymentAddress);
    }

    function setCreateAgentTokenCost(address paymentAddress, uint256 cost) public onlyOwner {
        require(paymentAddress != address(0), "Payment Address is invalid");

        require(paymentAddressEnableMp[paymentAddress], "Payment Address is not added");

        paymentOpCostMp[paymentAddress][CREATE_AGENT_OP] = cost;

        emit CreateAgentTokenCost(paymentAddress, cost);
    }

    function setUpdateCreateAgentTokenCost(address paymentAddress, uint256 cost) public onlyOwner {
        require(paymentAddress != address(0), "Payment Address is invalid");

        require(paymentAddressEnableMp[paymentAddress], "Payment Address is not added");

        paymentOpCostMp[paymentAddress][UPDATE_AGENT_OP] = cost;

        emit UpdateAgentTokenCost(paymentAddress, cost);
    }

    function removePaymentAddress(address paymentAddress) public onlyOwner {
        require(paymentAddress != address(0), "Payment Address is invalid");

        require(paymentAddressEnableMp[paymentAddress], "Payment Address is not added");

        // soft remove
        paymentAddressEnableMp[paymentAddress] = false;

        emit RemovePaymentAddress(paymentAddress);
    }

    function setFeeCollectionWalletAddress(address _feeCollectionWalletAddress) public onlyOwner {
        require(_feeCollectionWalletAddress != address(0), "Fee collection Wallet Address is invalid");
        feeCollectionWalletAddress = _feeCollectionWalletAddress;

        emit FeeCollectionWalletAddress(_feeCollectionWalletAddress);
    }
}
