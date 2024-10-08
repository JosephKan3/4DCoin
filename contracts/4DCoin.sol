// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PointsSystemWithQueue is ERC20 {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct QueueItem {
        address wallet;
        uint256 stakedTokens;
        uint256 timestamp;
    }

    EnumerableSet.AddressSet private registeredWallets;
    mapping(address => uint256) public registrationTime;
    mapping(address => uint256) public lastUpdateTime;
    mapping(address => uint256) public restrictedBalance;

    QueueItem[] public queue;
    mapping(address => uint256) public queuePositions;

    uint256 public constant DISTRIBUTION_INTERVAL = 10 seconds;
    uint256 public constant REGULAR_DISTRIBUTION_RATE = 10 * 10**18 / DISTRIBUTION_INTERVAL;
    uint256 public constant RESTRICTED_DISTRIBUTION_RATE = 5 * 10**18 / DISTRIBUTION_INTERVAL;

    event WalletRegistered(address wallet);
    event EnteredQueue(address wallet, uint256 stakedTokens);
    event QueueUpdated(address wallet, uint256 newPosition);
    event ItemDequeued(address wallet, uint256 consumedTokens);

    constructor() ERC20("4D Coin", "4D") {}

    function registerWallet() external {
        require(!isRegistered(msg.sender), "Wallet already registered");
        registrationTime[msg.sender] = block.timestamp;
        lastUpdateTime[msg.sender] = block.timestamp;
        registeredWallets.add(msg.sender);
        emit WalletRegistered(msg.sender);
    }

    function getRegisteredWallets() external view returns (address[] memory) {
        return registeredWallets.values();
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
        require(isRegistered(msg.sender), "Sender is not registered.");
        require(isRegistered(recipient), "Recipient is not registered.");

        updatePoints(msg.sender);
        updatePoints(recipient);

        require(amount <= balanceOf(msg.sender) + restrictedBalance[msg.sender], "Transfer amount exceeds balance");

        // Prioritize transferring restricted balance
        uint256 transferred_restricted_coins = amount > restrictedBalance[msg.sender] ? restrictedBalance[msg.sender] : amount;
        uint256 remaining_restricted_balance = restrictedBalance[msg.sender] - transferred_restricted_coins;

        uint256 transferred_regular_coins = amount - transferred_restricted_coins;

        // Logically these should never be needed, but safety is king
        require(transferred_regular_coins <= balanceOf(msg.sender), "Not enough regular coins to transfer.");
        require(transferred_restricted_coins <= restrictedBalance[msg.sender]);

        restrictedBalance[msg.sender] = remaining_restricted_balance;
        _mint(recipient, transferred_restricted_coins);
        return super.transfer(recipient, transferred_regular_coins);

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

    function enterQueue(uint256 amount) external {
        updatePoints(msg.sender);
        require(isRegistered(msg.sender), "Wallet not registered");
        require(amount <= balanceOf(msg.sender), "Insufficient balance");

        _burn(msg.sender, amount);  // Burn the staked tokens

        uint256 insertPosition = findInsertPosition(amount);
        queue.push(QueueItem({
            wallet: msg.sender,
            stakedTokens: amount,
            timestamp: block.timestamp
        }));

        // Shift items and update positions
        for (uint256 i = queue.length - 1; i > insertPosition; i--) {
            queue[i] = queue[i - 1];
            queuePositions[queue[i].wallet] = i;
        }
        queue[insertPosition] = QueueItem({
            wallet: msg.sender,
            stakedTokens: amount,
            timestamp: block.timestamp
        });
        queuePositions[msg.sender] = insertPosition;

        emit EnteredQueue(msg.sender, amount);
        emit QueueUpdated(msg.sender, insertPosition);
    }

    function findInsertPosition(uint256 stakedTokens) internal view returns (uint256) {
        for (uint256 i = 0; i < queue.length; i++) {
            if (stakedTokens > queue[i].stakedTokens) {
                return i;
            }
        }
        return queue.length;
    }

    function dequeueItem() external {
        require(queue.length > 0, "Queue is empty");
        
        QueueItem memory dequeuedItem = queue[0];
        uint256 consumedTokens = dequeuedItem.stakedTokens;

        // Remove the first item and shift the rest
        for (uint256 i = 0; i < queue.length - 1; i++) {
            queue[i] = queue[i + 1];
            queuePositions[queue[i].wallet] = i;
        }
        queue.pop();

        // Remove the position mapping for the dequeued item
        delete queuePositions[dequeuedItem.wallet];

        emit ItemDequeued(dequeuedItem.wallet, consumedTokens);
    }

    function getQueueLength() external view returns (uint256) {
        return queue.length;
    }

    function getQueuePosition(address wallet) external view returns (uint256) {
        require(queuePositions[wallet] > 0 || (queue.length > 0 && queue[0].wallet == wallet), "Wallet not in queue");
        return queuePositions[wallet];
    }

    function getQueueContents() external view returns (QueueItem[] memory) {
        return queue;
    }

    function getAllAccountBalances() external view returns (address[] memory, uint256[] memory, uint256[] memory) {
        address[] memory addresses = new address[](registeredWallets.length());
        uint256[] memory regularBalances = new uint256[](registeredWallets.length());
        uint256[] memory restrictedBalances = new uint256[](registeredWallets.length());

        for (uint256 i = 0; i < registeredWallets.length(); i++) {
            address wallet = registeredWallets.at(i);
            addresses[i] = wallet;
            regularBalances[i] = balanceOf(wallet);
            restrictedBalances[i] = getRestrictedBalance(wallet);
        }

        return (addresses, regularBalances, restrictedBalances);
    }

}