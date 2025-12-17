// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Factory} from "./interfaces/IERC20Factory.sol";
import {ERC20Token} from "./ERC20Token.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title ERC20Factory
 * @notice Factory contract for creating slashed ERC20 tokens
 * @dev Creates mintable/burnable ERC20 tokens for representing vault shares
 */
contract ERC20Factory is IERC20Factory, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EmptyString();
    error IndexOutOfBounds();

    /*//////////////////////////////////////////////////////////////
                        NAMESPACED STORAGE (ERC-7201)
    //////////////////////////////////////////////////////////////*/

    /// @custom:storage-location erc7201:erc20.factory.storage
    struct FactoryStorage {
        /// @dev Array of all tokens created by this factory
        address[] tokens;
        /// @dev Mapping from token address to creation status
        mapping(address => bool) isToken;
    }

    // keccak256(abi.encode(uint256(keccak256("erc20.factory.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORY_STORAGE_LOCATION =
        0x5c57fc7b6bf6ceeaa106d807cc261837d3f0a0c5e72fcba25c00753c6ce2b900;

    function _getFactoryStorage() private pure returns (FactoryStorage storage $) {
        assembly {
            $.slot := FACTORY_STORAGE_LOCATION
        }
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Modifier to ensure the string is not empty
     * @param _str The string to check
     */
    modifier nonEmptyString(string memory _str) {
        if (bytes(_str).length == 0) revert EmptyString();
        _;
    }

    /**
     * @notice Modifier to ensure the index is within bounds
     * @param _index The index to check
     */
    modifier validIndex(uint256 _index) {
        if (_index >= _getFactoryStorage().tokens.length) revert IndexOutOfBounds();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Constructs the ERC20Factory contract
     * @param _owner The owner of the contract
     */
    constructor(address _owner) Ownable(_owner) {}

    /*//////////////////////////////////////////////////////////////
                          PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a new ERC20 token
     * @param name The name of the token
     * @param symbol The symbol of the token
     * @param decimals The number of decimals for the token (typically 18)
     * @return token The address of the newly created token
     */
    function createToken(string memory name, string memory symbol, uint8 decimals)
        external
        override
        onlyOwner
        nonEmptyString(name)
        nonEmptyString(symbol)
        returns (address token)
    {
        // Deploy new token
        ERC20Token newToken = new ERC20Token(name, symbol, decimals, msg.sender);
        token = address(newToken);

        // Track the token
        FactoryStorage storage $ = _getFactoryStorage();
        $.tokens.push(token);
        $.isToken[token] = true;

        // Emit event
        emit TokenCreated(token, name, symbol, msg.sender);

        return token;
    }

    /**
     * @notice Gets the number of tokens created by this factory
     * @return count The number of tokens created
     */
    function getTokenCount() external view override returns (uint256 count) {
        return _getFactoryStorage().tokens.length;
    }

    /**
     * @notice Gets the address of a token by its index
     * @param index The index of the token
     * @return token The address of the token
     */
    function getToken(uint256 index) external view override validIndex(index) returns (address token) {
        return _getFactoryStorage().tokens[index];
    }

    /**
     * @notice Gets all tokens created by this factory
     * @return tokens Array of all token addresses
     */
    function getAllTokens() external view returns (address[] memory tokens) {
        return _getFactoryStorage().tokens;
    }

    /**
     * @notice Checks if an address is a token created by this factory
     * @param token The address to check
     * @return Whether the address is a token created by this factory
     */
    function isToken(address token) external view override returns (bool) {
        return _getFactoryStorage().isToken[token];
    }
}

