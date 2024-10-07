// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PointsSystem is ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private registeredWallets;
    mapping(address => uint256) public registrationTime;
    mapping(address => uint256) public lastUpdateTime;
    mapping(address => uint256) public restrictedBalance;

    uint256 public constant DISTRIBUTION_INTERVAL = 10 seconds;
    uint256 public constant REGULAR_DISTRIBUTION_RATE = 10 * 10**18 / DISTRIBUTION_INTERVAL; // 100 tokens per interval
    uint256 public constant RESTRICTED_DISTRIBUTION_RATE = 5 * 10**18 / DISTRIBUTION_INTERVAL; // 50 tokens per interval

    event WalletRegistered(address wallet);

    constructor() ERC20("4D Coin", "4D") {}

    function registerWallet() external {
        require(!isRegistered(msg.sender), "Wallet already registered");
        registrationTime[msg.sender] = block.timestamp;
        lastUpdateTime[msg.sender] = block.timestamp;
        registeredWallets.add(msg.sender);
        emit WalletRegistered(msg.sender);
    }

    function isRegistered(address wallet) public view returns (bool) {
        return registeredWallets.contains(wallet);
    }

    function updatePoints(address wallet) internal {
        if (!isRegistered(wallet)) return;

        uint256 timePassed = block.timestamp - lastUpdateTime[wallet];
        uint256 newRegularPoints = timePassed * REGULAR_DISTRIBUTION_RATE;
        uint256 newRestrictedPoints = timePassed * RESTRICTED_DISTRIBUTION_RATE;

        _mint(wallet, newRegularPoints);
        restrictedBalance[wallet] += newRestrictedPoints;
        lastUpdateTime[wallet] = block.timestamp;
    }

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        updatePoints(msg.sender);
        updatePoints(recipient);

        require(amount <= balanceOf(msg.sender), "Transfer amount exceeds balance");

        uint remaining_restricted_balance = amount > restrictedBalance[msg.sender] ? 0 : restrictedBalance[msg.sender] - amount;
        restrictedBalance[msg.sender] = remaining_restricted_balance;

        return super.transfer(recipient, amount);
    }

    function balanceOf(address account) public view virtual override returns (uint256) {
        uint256 baseBalance = super.balanceOf(account);
        if (!isRegistered(account)) return baseBalance;

        uint256 timePassed = block.timestamp - lastUpdateTime[account];
        uint256 newPoints = timePassed * REGULAR_DISTRIBUTION_RATE;
        return baseBalance + newPoints;
    }

    function getRestrictedBalance(address account) public view returns (uint256) {
        if (!isRegistered(account)) return 0;

        uint256 timePassed = block.timestamp - lastUpdateTime[account];
        uint256 newPoints = timePassed * RESTRICTED_DISTRIBUTION_RATE;
        return restrictedBalance[account] + newPoints;
    }

    function getRegisteredWallets() external view returns (address[] memory) {
        return registeredWallets.values();
    }
}