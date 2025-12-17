// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IERC20Factory
 * @notice Interface for ERC20 token factory
 */
interface IERC20Factory {
    /**
     * @notice Emitted when a new ERC20 token is created
     * @param token The address of the newly created token
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param creator The address that created the token (msg.sender of createToken)
     */
    event TokenCreated(address indexed token, string name, string symbol, address indexed creator);

    /**
     * @notice Creates a new ERC20 token
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals The number of decimals for the token
     * @return token The address of the newly created token
     */
    function createToken(string memory name, string memory symbol, uint8 decimals) external returns (address token);

    /**
     * @notice Gets the number of tokens created by this factory
     * @return count The number of tokens created
     */
    function getTokenCount() external view returns (uint256 count);

    /**
     * @notice Gets the address of a token by its index
     * @param index The index of the token
     * @return token The address of the token
     */
    function getToken(uint256 index) external view returns (address token);

    /**
     * @notice Checks if an address is a token created by this factory
     * @param token The address to check
     * @return isToken Whether the address is a token created by this factory
     */
    function isToken(address token) external view returns (bool isToken);
}

