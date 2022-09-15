// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "./interface/IDrop1155.sol";
import "../lib/MerkleProof.sol";
import "../lib/TWBitMaps.sol";

abstract contract Drop1155 is IDrop1155 {
    using TWBitMaps for TWBitMaps.BitMap;

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from token ID => the set of all claim conditions, at any given moment, for tokens of the token ID.
    mapping(uint256 => ClaimConditionList) public claimCondition;

    /*///////////////////////////////////////////////////////////////
                            Drop logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Lets an account claim tokens.
    function claim(
        address _receiver,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) public payable virtual override {
        _beforeClaim(_tokenId, _receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);

        uint256 activeConditionId = getActiveClaimConditionId(_tokenId);
        ClaimCondition memory currentClaimPhase = claimCondition[_tokenId].conditions[activeConditionId];

        /**
         *  We make allowlist checks (i.e. verifyClaimMerkleProof) before verifying the claim's general
         *  validity (i.e. verifyClaim) because we give precedence to the check of allow list quantity
         *  restriction over the check of the general claim condition's quantityLimitPerWallet
         *  restriction.
         */

        // Verify inclusion in allowlist.
        (bool validMerkleProof, uint256 merkleProofIndex) = verifyClaimMerkleProof(
            activeConditionId,
            _dropMsgSender(),
            _tokenId,
            _quantity,
            _allowlistProof
        );

        // Verify claim validity. If not valid, revert.
        // when there's allowlist present --> verifyClaimMerkleProof will verify the maxQuantityInAllowlist value with hashed leaf in the allowlist
        // when there's no allowlist, this check is true --> verifyClaim will check for _quantity being equal/less than the limit
        bool toVerifyMaxQuantityPerWallet = _allowlistProof.maxQuantityInAllowlist == 0 ||
            currentClaimPhase.merkleRoot == bytes32(0);

        verifyClaim(
            activeConditionId,
            _dropMsgSender(),
            _tokenId,
            _quantity,
            _currency,
            _pricePerToken,
            toVerifyMaxQuantityPerWallet
        );

        if (validMerkleProof) {
            if (
                _allowlistProof.maxQuantityInAllowlist > 0 &&
                _quantity + claimCondition[_tokenId].supplyClaimedByWallet[activeConditionId][_dropMsgSender()] ==
                _allowlistProof.maxQuantityInAllowlist
            ) {
                /**
                 *  Mark the claimer's use of their position in the allowlist. A spot in an allowlist
                 *  can be used only once.
                 */
                claimCondition[_tokenId].usedAllowlistSpot[activeConditionId].set(merkleProofIndex);
            }
        }

        // Update contract state.
        claimCondition[_tokenId].conditions[activeConditionId].supplyClaimed += _quantity;
        claimCondition[_tokenId].lastClaimTimestamp[activeConditionId][_dropMsgSender()] = block.timestamp;
        claimCondition[_tokenId].supplyClaimedByWallet[activeConditionId][_dropMsgSender()] += _quantity;

        // If there's a price, collect price.
        collectPriceOnClaim(address(0), _quantity, _currency, _pricePerToken);

        // Mint the relevant NFTs to claimer.
        transferTokensOnClaim(_receiver, _tokenId, _quantity); //-------refactor

        emit TokensClaimed(activeConditionId, _dropMsgSender(), _receiver, _tokenId, _quantity);

        _afterClaim(_tokenId, _receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);
    }

    /// @dev Lets a contract admin set claim conditions.
    function setClaimConditions(uint256 _tokenId, ClaimCondition[] calldata _conditions, bool _resetClaimEligibility)
        external
        virtual
        override
    {
        if (!_canSetClaimConditions()) {
            revert("Not authorized");
        }
        ClaimConditionList storage conditionList = claimCondition[_tokenId];
        uint256 existingStartIndex = conditionList.currentStartId;
        uint256 existingPhaseCount = conditionList.count;

        /**
         *  `lastClaimTimestamp`, `usedAllowListSpot`, and `supplyClaimedByWallet` are mappings that use a
         *  claim condition's UID as a key.
         *
         *  If `_resetClaimEligibility == true`, we assign completely new UIDs to the claim
         *  conditions in `_conditions`, effectively resetting the restrictions on claims expressed
         *  by `lastClaimTimestamp`, `usedAllowListSpot`, and `supplyClaimedByWallet`.
         */
        uint256 newStartIndex = existingStartIndex;
        if (_resetClaimEligibility) {
            newStartIndex = existingStartIndex + existingPhaseCount;
        }

        conditionList.count = _conditions.length;
        conditionList.currentStartId = newStartIndex;

        uint256 lastConditionStartTimestamp;
        for (uint256 i = 0; i < _conditions.length; i++) {
            require(i == 0 || lastConditionStartTimestamp < _conditions[i].startTimestamp, "ST");

            uint256 supplyClaimedAlready = conditionList.conditions[newStartIndex + i].supplyClaimed;
            if (supplyClaimedAlready > _conditions[i].maxClaimableSupply) {
                revert("max supply claimed");
            }

            conditionList.conditions[newStartIndex + i] = _conditions[i];
            conditionList.conditions[newStartIndex + i].supplyClaimed = supplyClaimedAlready; //------what are we doing here?

            lastConditionStartTimestamp = _conditions[i].startTimestamp;
        }

        /**
         *  Gas refunds (as much as possible)
         *
         *  If `_resetClaimEligibility == true`, we assign completely new UIDs to the claim
         *  conditions in `_conditions`. So, we delete claim conditions with UID < `newStartIndex`.
         *
         *  If `_resetClaimEligibility == false`, and there are more existing claim conditions
         *  than in `_conditions`, we delete the existing claim conditions that don't get replaced
         *  by the conditions in `_conditions`.
         */
        if (_resetClaimEligibility) {
            for (uint256 i = existingStartIndex; i < newStartIndex; i++) {
                delete conditionList.conditions[i];
                delete conditionList.usedAllowlistSpot[i];
            }
        } else {
            if (existingPhaseCount > _conditions.length) {
                for (uint256 i = _conditions.length; i < existingPhaseCount; i++) {
                    delete conditionList.conditions[newStartIndex + i];
                    delete conditionList.usedAllowlistSpot[newStartIndex + i];
                }
            }
        }

        emit ClaimConditionsUpdated(_tokenId, _conditions, _resetClaimEligibility);
    }

    /// @dev Checks a request to claim NFTs against the active claim condition's criteria.
    function verifyClaim(
        uint256 _conditionId,
        address _claimer,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        bool verifyMaxQuantityPerWallet
    ) public view {
        ClaimCondition memory currentClaimPhase = claimCondition[_tokenId].conditions[_conditionId];
        uint256 supplyClaimedByWallet = _quantity + claimCondition[_tokenId].supplyClaimedByWallet[_conditionId][_claimer];

        if (_currency != currentClaimPhase.currency || _pricePerToken != currentClaimPhase.pricePerToken) {
            revert("!PriceOrCurrency");
        }

        // If we're checking for an allowlist quantity restriction, ignore the general quantity restriction.
        if (
            _quantity == 0 ||
            (verifyMaxQuantityPerWallet && supplyClaimedByWallet > currentClaimPhase.quantityLimitPerWallet)
        ) {
            revert("!Qty");
        }
        if (currentClaimPhase.supplyClaimed + _quantity > currentClaimPhase.maxClaimableSupply) {
            revert("!MaxSupply");
        }

        (uint256 lastClaimedAt, uint256 nextValidClaimTimestamp) = getClaimTimestamp(_tokenId, _conditionId, _claimer);
        if (
            currentClaimPhase.startTimestamp > block.timestamp ||
            (lastClaimedAt != 0 && block.timestamp < nextValidClaimTimestamp)
        ) {
            revert("cant claim yet");
        }
    }

    /// @dev Checks whether a claimer meets the claim condition's allowlist criteria.
    function verifyClaimMerkleProof(
        uint256 _conditionId,
        address _claimer,
        uint256 _tokenId,
        uint256 _quantity,
        AllowlistProof calldata _allowlistProof
    ) public view returns (bool validMerkleProof, uint256 merkleProofIndex) {
        ClaimCondition memory currentClaimPhase = claimCondition[_tokenId].conditions[_conditionId];
        uint256 supplyClaimedByWallet = _quantity + claimCondition[_tokenId].supplyClaimedByWallet[_conditionId][_claimer];

        if (currentClaimPhase.merkleRoot != bytes32(0)) {
            (validMerkleProof, merkleProofIndex) = MerkleProof.verify(
                _allowlistProof.proof,
                currentClaimPhase.merkleRoot,
                keccak256(abi.encodePacked(_claimer, _allowlistProof.maxQuantityInAllowlist))
            );
            if (!validMerkleProof) {
                revert("!Allowlist");
            }

            if (claimCondition[_tokenId].usedAllowlistSpot[_conditionId].get(merkleProofIndex)) {
                revert("proof claimed");
            }

            if (
                _allowlistProof.maxQuantityInAllowlist != 0 &&
                supplyClaimedByWallet > _allowlistProof.maxQuantityInAllowlist
            ) {
                revert("!Qty");
            }
        }
    }

    /// @dev At any given moment, returns the uid for the active claim condition.
    function getActiveClaimConditionId(uint256 _tokenId) public view returns (uint256) {
        ClaimConditionList storage conditionList = claimCondition[_tokenId];
        for (uint256 i = conditionList.currentStartId + conditionList.count; i > conditionList.currentStartId; i--) {
            if (block.timestamp >= conditionList.conditions[i - 1].startTimestamp) {
                return i - 1;
            }
        }

        revert("!CONDITION.");
    }

    /// @dev Returns the claim condition at the given uid.
    function getClaimConditionById(uint256 _tokenId, uint256 _conditionId) external view returns (ClaimCondition memory condition) {
        condition = claimCondition[_tokenId].conditions[_conditionId];
    }

    /// @dev Returns the timestamp for when a claimer is eligible for claiming NFTs again.
    function getClaimTimestamp(uint256 _tokenId, uint256 _conditionId, address _claimer)
        public
        view
        returns (uint256 lastClaimTimestamp, uint256 nextValidClaimTimestamp)
    {
        lastClaimTimestamp = claimCondition[_tokenId].lastClaimTimestamp[_conditionId][_claimer];

        unchecked {
            nextValidClaimTimestamp =
                lastClaimTimestamp +
                claimCondition[_tokenId].conditions[_conditionId].waitTimeInSecondsBetweenClaims;

            if (nextValidClaimTimestamp < lastClaimTimestamp) {
                nextValidClaimTimestamp = type(uint256).max;
            }
        }
    }

    /// @dev Returns the supply claimed by claimer for a given conditionId.
    function getSupplyClaimedByWallet(uint256 _tokenId, uint256 _conditionId, address _claimer)
        public
        view
        returns (uint256 supplyClaimedByWallet)
    {
        supplyClaimedByWallet = claimCondition[_tokenId].supplyClaimedByWallet[_conditionId][_claimer];
    }

    /*////////////////////////////////////////////////////////////////////
        Optional hooks that can be implemented in the derived contract
    ///////////////////////////////////////////////////////////////////*/

    /// @dev Exposes the ability to override the msg sender.
    function _dropMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /// @dev Runs before every `claim` function call.
    function _beforeClaim(
        uint256 _tokenId,
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /// @dev Runs after every `claim` function call.
    function _afterClaim(
        uint256 _tokenId,
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /*///////////////////////////////////////////////////////////////
        Virtual functions: to be implemented in derived contract
    //////////////////////////////////////////////////////////////*/

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function collectPriceOnClaim(
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal virtual;

    /// @dev Transfers the NFTs being claimed.
    function transferTokensOnClaim(address _to, uint256 _tokenId, uint256 _quantityBeingClaimed)
        internal
        virtual;

    /// @dev Determine what wallet can update claim conditions
    function _canSetClaimConditions() internal view virtual returns (bool);
}
