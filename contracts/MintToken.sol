// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MintToken is ERC20 {
    uint256 initialSupply = 100000 * (10 ** 18);
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        _mint(msg.sender, initialSupply);
    }

    function mintToken(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burnToken(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
