// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@thirdweb-dev/contracts/eip/ERC721A.sol";
import "@thirdweb-dev/contracts/eip/interface/IERC721Enumerable.sol";

contract Contract is ERC721A, IERC721Enumerable {
    constructor(
        string memory _name,
        string memory _symbol
    )
        ERC721A(
            _name,
            _symbol
        )
    {}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@thirdweb-dev/contracts/eip/ERC721A.sol";
import "@thirdweb-dev/contracts/eip/interface/IERC721Enumerable.sol";

contract Contract is ERC721A, IERC721Enumerable {
    constructor(
        string memory _name,
        string memory _symbol
    )
        ERC721A(
            _name,
            _symbol
        )
    {}

    function tokenByIndex(uint256 _index) external view override returns (uint256) {
        // Your custom implementation here
    }

    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view override returns (uint256) {
        // Your custom implementation here
    }
}

    function tokenByIndex(uint256 _index) external view override returns (uint256) {
        // Your custom implementation here
    }

    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view override returns (uint256) {
        // Your custom implementation here
    }
}

/// @title ERC-721 Non-Fungible Token Standard, optional enumeration extension
/// @dev See https://eips.ethereum.org/EIPS/eip-721
///  Note: the ERC-165 identifier for this interface is 0x780e9d63.
/* is ERC721 */
interface IERC721Enumerable {
    /// @notice Enumerate valid NFTs
    /// @dev Throws if `_index` >= `totalSupply()`.
    /// @param _index A counter less than `totalSupply()`
    /// @return The token identifier for the `_index`th NFT,
    ///  (sort order not specified)
    function tokenByIndex(uint256 _index) external view returns (uint256);

    /// @notice Enumerate NFTs assigned to an owner
    /// @dev Throws if `_index` >= `balanceOf(_owner)` or if
    ///  `_owner` is the zero address, representing invalid NFTs.
    /// @param _owner An address where we are interested in NFTs owned by them
    /// @param _index A counter less than `balanceOf(_owner)`
    /// @return The token identifier for the `_index`th NFT assigned to `_owner`,
    ///   (sort order not specified)
    function tokenOfOwnerByIndex(address _owner, uint256 _index) external view returns (uint256);
}
