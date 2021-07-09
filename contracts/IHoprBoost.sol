// SPDX-License-Identifier: GPL-3.0-only

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IHoprBoost is IERC721 {
    /**
     * @dev Returns the boost associated with ``tokenId``.
     */
    function boostFactorOf(uint256 tokenId) external view returns (uint256);
    
    /**
     * @dev Returns the boost type index associated with ``tokenId``.
     */
    function typeOf(uint256 tokenId) external view returns (uint256);
}