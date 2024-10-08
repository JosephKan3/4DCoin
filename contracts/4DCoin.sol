// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./CustomMath.sol";

contract FourthDimensionCoin is ERC20, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    struct QueueItem {
        uint256 uuid;
        address wallet;
        uint256 weight;
        uint256 queuePriorityValue;
        uint256 stakedCoins;
        uint256 timestamp;
        uint256 stl_uuid;
    }


    EnumerableSet.AddressSet private registeredWallets;
    mapping(address => uint256) public registrationTime;
    mapping(address => uint256) public lastUpdateTime;
    mapping(address => uint256) public restrictedBalance;

    QueueItem[] public queue;
    mapping(uint256 => uint256) public queuePositions; // Maps stl_uuid to queue position

    uint256 public constant DISTRIBUTION_INTERVAL = 10 seconds;
    uint256 public constant REGULAR_DISTRIBUTION_RATE = 10 * 10**18 / DISTRIBUTION_INTERVAL;
    uint256 public constant RESTRICTED_DISTRIBUTION_RATE = 5 * 10**18 / DISTRIBUTION_INTERVAL;

    address public dappAddress;

    event WalletRegistered(address wallet);
    event EnteredQueue(address wallet, uint256 stakedTokens, uint256 stl_uuid);
    event QueueUpdated(address wallet, uint256 newPosition, uint256 stl_uuid);
    event ItemDequeued(address wallet, uint256 consumedTokens, uint256 stl_uuid);
    event StakeRemoved(address wallet, uint256 returnedTokens, uint256 stl_uuid);
    event StakeChanged(address wallet, uint256 newStakedTokens, uint256 stl_uuid);

    constructor(address _dappAddress) ERC20("4D Coin", "4D") Ownable(msg.sender) {
        dappAddress = _dappAddress;
    }

    // Coin functions
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

    // Queue functions
    function findInsertPosition(uint256 weight, uint256 queuePriorityValue) internal view returns (uint256) {
        for (uint256 i = 0; i < queue.length; i++) {
            if (queuePriorityValue > queue[i].queuePriorityValue ||
                (queuePriorityValue == queue[i].queuePriorityValue && weight < queue[i].weight) ||
                (queuePriorityValue == queue[i].queuePriorityValue && weight == queue[i].weight && block.timestamp < queue[i].timestamp)) {
                return i;
            }
        }
        return queue.length;
    }

    function calculateInsertionCost(uint256 weight, uint256 queuePriorityValue) public pure returns (uint256) {
        return Logarithm.logBase(weight, 1.2 * 1e18) * queuePriorityValue * 10**18;
    }

    function calculatePriorityValue(uint256 weight, uint256 staked_coins) public pure returns (uint256) {
        return staked_coins / Logarithm.logBase(weight * 1e18, 1.2 * 1e18) / 10**18;
    }

    function removeStakeFromQueue(uint256 stl_uuid) external {
        require(queuePositions[stl_uuid] > 0 || (queue.length > 0 && queue[0].stl_uuid == stl_uuid), "No stake found in queue");
        
        uint256 position = queuePositions[stl_uuid];
        uint256 returnedTokens = queue[position].stakedCoins;

        // Remove the item and shift the rest
        for (uint256 i = position; i < queue.length - 1; i++) {
            queue[i] = queue[i + 1];
            queuePositions[queue[i].stl_uuid] = i;
        }
        queue.pop();

        // Remove the position mapping for the removed item
        delete queuePositions[stl_uuid];

        // Return the staked tokens
        _mint(msg.sender, returnedTokens);

        emit StakeRemoved(msg.sender, returnedTokens, stl_uuid);
    }

    function changeStakeBalance(uint256 newWeight, uint256 newQueuePriorityValue, uint256 stl_uuid) external {
        require(queuePositions[stl_uuid] > 0 || (queue.length > 0 && queue[0].stl_uuid == stl_uuid), "No stake found in queue");
        
        uint256 position = queuePositions[stl_uuid];
        uint256 oldStakedCoins = queue[position].stakedCoins;
        uint256 newStakedCoins = calculateInsertionCost(newWeight, newQueuePriorityValue);

        if (newStakedCoins > oldStakedCoins) {
            uint256 additionalStake = newStakedCoins - oldStakedCoins;
            require(balanceOf(msg.sender) >= additionalStake, "Insufficient balance for additional stake");
            _burn(msg.sender, additionalStake);
        } else if (newStakedCoins < oldStakedCoins) {
            uint256 returnedTokens = oldStakedCoins - newStakedCoins;
            _mint(msg.sender, returnedTokens);
        }

        // Update the stake
        queue[position].weight = newWeight;
        queue[position].queuePriorityValue = newQueuePriorityValue;
        queue[position].stakedCoins = newStakedCoins;
        queue[position].timestamp = block.timestamp;

        // Reorder the queue
        _reorderQueue(position);

        emit StakeChanged(msg.sender, newStakedCoins, stl_uuid);
    }

    function _reorderQueue(uint256 startPosition) internal {
        QueueItem memory item = queue[startPosition];
        uint256 newPosition = findInsertPosition(item.weight, item.queuePriorityValue);

        if (newPosition < startPosition) {
            // Move up in the queue
            for (uint256 i = startPosition; i > newPosition; i--) {
                queue[i] = queue[i - 1];
                queuePositions[queue[i].stl_uuid] = i;
            }
        } else if (newPosition > startPosition) {
            // Move down in the queue
            newPosition--; // Adjust for the removal of the current item
            for (uint256 i = startPosition; i < newPosition; i++) {
                queue[i] = queue[i + 1];
                queuePositions[queue[i].stl_uuid] = i;
            }
        } else {
            // Position hasn't changed
            return;
        }

        queue[newPosition] = item;
        queuePositions[item.stl_uuid] = newPosition;

        emit QueueUpdated(item.wallet, newPosition, item.stl_uuid);
    }

    function enterQueue(uint256 weight, uint256 queuePriorityValue, uint256 stl_uuid) external {
        updatePoints(msg.sender);
        require(isRegistered(msg.sender), "Wallet not registered");
        require(queuePositions[stl_uuid] == 0, "STL UUID already in queue");
        
        uint256 cost = calculateInsertionCost(weight, queuePriorityValue);
        require(balanceOf(msg.sender) >= cost, string.concat("Insufficient balance: ", Strings.toString(balanceOf(msg.sender)), ", expected: ", Strings.toString(cost)));

        _burn(msg.sender, cost);  // Burn the insertion cost

        uint256 insertPosition = findInsertPosition(weight, queuePriorityValue);
        QueueItem memory newItem = QueueItem({
            uuid: queue.length, // Use array index as UUID
            wallet: msg.sender,
            weight: weight,
            queuePriorityValue: queuePriorityValue,
            stakedCoins: cost,
            timestamp: block.timestamp,
            stl_uuid: stl_uuid
        });

        if (insertPosition == queue.length) {
            queue.push(newItem);
        } else {
            queue.push(queue[queue.length - 1]);
            for (uint256 i = queue.length - 1; i > insertPosition; i--) {
                queue[i] = queue[i - 1];
                queuePositions[queue[i].stl_uuid] = i;
            }
            queue[insertPosition] = newItem;
        }

        queuePositions[stl_uuid] = insertPosition;

        emit EnteredQueue(msg.sender, cost, stl_uuid);
        emit QueueUpdated(msg.sender, insertPosition, stl_uuid);
    }


    function getQueueLength() external view returns (uint256) {
        return queue.length;
    }

    function getQueuePosition(uint256 stl_uuid) external view returns (uint256) {
        require(queuePositions[stl_uuid] > 0 || (queue.length > 0 && queue[0].stl_uuid == stl_uuid), "STL UUID not in queue");
        return queuePositions[stl_uuid];
    }

    function getQueueContents() external view returns (QueueItem[] memory) {
        return queue;
    }

    // Owner functions
    function dequeueItem() external {
        require(msg.sender == dappAddress, "Only the dapp can dequeue items");
        require(queue.length > 0, "Queue is empty");
        
        QueueItem memory dequeuedItem = queue[0];
        uint256 consumedTokens = dequeuedItem.stakedCoins;

        // Remove the first item and shift the rest
        for (uint256 i = 0; i < queue.length - 1; i++) {
            queue[i] = queue[i + 1];
            queuePositions[queue[i].stl_uuid] = i;
        }
        queue.pop();

        // Remove the position mapping for the dequeued item
        delete queuePositions[dequeuedItem.stl_uuid];

        emit ItemDequeued(dequeuedItem.wallet, consumedTokens, dequeuedItem.stl_uuid);
    }

    // function refundItem() external {
    // }

    function setDappAddress(address _newDappAddress) external onlyOwner {
        dappAddress = _newDappAddress;
    }
    
}