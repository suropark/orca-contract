// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "openzeppelin-solidity/contracts/introspection/ERC165.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";


contract ORCAToken is ERC20("ORCA Finance Token", "ORCA"), ERC165, Ownable {
    constructor() public {
        _registerInterface(0x36372b07); // ERC-20. Not equals with _INTERFACE_ID_KIP7
        _registerInterface(0xa219a025); // ERC-20 Detailed. Equals with _INTERFACE_ID_KIP7_METADATA
		_mint(msg.sender, 750000e18);
	}

    function mint(address _to, uint256 _amount) public onlyOwner {
        _mint(_to, _amount);
    }
}
