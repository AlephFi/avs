// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

/**
 * @title IMintableBurnableERC20
 * @notice Interface for ERC20 tokens that support minting and burning
 */
interface IMintableBurnableERC20 {
    /**
     * @notice Mints new tokens to the specified address
     * @param to The address to receive the tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the specified address
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;
}

