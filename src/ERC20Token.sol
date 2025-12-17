// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Token
 * @notice Mintable/burnable ERC20 token for representing slashed vault shares
 * @dev On Sepolia testnet, anyone can mint and burn tokens for testing purposes.
 *      On all other chains (including mainnet), only the owner (AlephAVS) can mint and burn tokens.
 */
contract ERC20Token is ERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emitted when tokens are minted
     * @param to The address receiving the minted tokens
     * @param amount The amount of tokens minted
     */
    event SlashedTokenMinted(address indexed to, uint256 amount);

    /**
     * @notice Emitted when tokens are burned
     * @param from The address whose tokens are burned
     * @param amount The amount of tokens burned
     */
    event SlashedTokenBurned(address indexed from, uint256 amount);

    uint8 private immutable DECIMALS;

    /// @dev Mainnet chain ID (1)
    uint256 private constant MAINNET_CHAIN_ID = 1;
    /// @dev Sepolia testnet chain ID (11155111)
    uint256 private constant SEPOLIA_CHAIN_ID = 11155111;

    /**
     * @notice Constructs the ERC20Token contract
     * @param _name The name of the token
     * @param _symbol The symbol of the token
     * @param _decimals The number of decimals for the token
     * @param _owner The owner of the contract
     */
    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _owner)
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        DECIMALS = _decimals;
    }

    /**
     * @notice Returns the number of decimals for the token
     * @return The number of decimals
     */
    function decimals() public view virtual override returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Mints new tokens to the specified address
     * @param to The address to receive the tokens
     * @param amount The amount of tokens to mint
     * @dev On Sepolia testnet, anyone can mint. On other chains, only the owner can mint.
     */
    function mint(address to, uint256 amount) external {
        // On Sepolia testnet, allow anyone to mint. On other chains, require owner.
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            // Sepolia testnet - allow anyone, no owner check needed
        } else {
            _checkOwner();
        }
        _mint(to, amount);
        emit SlashedTokenMinted(to, amount);
    }

    /**
     * @notice Burns tokens from the specified address
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     * @dev On Sepolia testnet, anyone can burn. On other chains, only the owner can burn.
     */
    function burn(address from, uint256 amount) external {
        // On Sepolia testnet, allow anyone to burn. On other chains, require owner.
        if (block.chainid == SEPOLIA_CHAIN_ID) {
            // Sepolia testnet - allow anyone, no owner check needed
        } else {
            _checkOwner();
        }
        _burn(from, amount);
        emit SlashedTokenBurned(from, amount);
    }
}

