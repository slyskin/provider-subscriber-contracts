// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/**
 * @title SubscriptionManager
 *
 * @notice Contract for a Provider-Subscriber system, where Providers offer some services for a monthly fee
 * and these services are consumed by Subscribers.
 *
 * @dev Things to note:
 * 1. In the code, `epoch` means one billing cycle.
 * Currently, it is set to 1 month.
 * This can be changed to 1 week or 1 day, according to our needs, by changing the value of the `EPOCH_LENGTH` constant.
 *
 * 2. In order to make the billing process fair and reliable, we use the Prepaid Subscription plan.
 * Subscribers have to pay the fee for the first epoch when they start using a Provider's service.
 * They can use the service for 1 epoch, and then at the end of the epoch, they have to pay the fee again to continue using the service.
 * If a subscriber doesn't have enough funds to pay the fees, his subscription is automatically paused.
 *
 * Benefits over Postpaid Subscription plan:
 *  - Guarantees that the providers always get paid for their services.
 *    If we use the Postpaid Subscription, there is no guarantee that the subscriber would deposit funds until the end of an epoch.
 *
 *  - Enables us to change the provider fees in the middle of an epoch.
 *    We just need to update the `fee` field of the Provider, and this change will come into effect from the next epoch.
 *    Subscribers can see this change, and if the fee is unacceptable, they can pause the subscription.
 *
 *  - Makes the billing process simpler and more straightforward.
 *
 * 3. We use the Chainlink automation to check periodically(e.g., daily) if there are any subscribers due to payment.
 *
 * 4. I used the `uint256` type for Provider ID for the system scalability.
 * If we are gonna stick with the restriction of the maximum number of providers to 200, we can use a Byte for it.
 * So, instead of `uint[]`, we can use `bytes` for `providerIds` array to save the storage cost.
 *
 * @dev Suggestions for further improvements:
 * 1. Separate the subscriber registration and subscription.
 * Currently, we ask the subscribers to specify which Providers they want to subscribe to at the point of registration,
 * and they cannot change it afterward.
 * We can add separate functions for registration and subscription, so that the subscribers can subscribe to any Providers they want at any time.
 *
 * 2. Let the subscribers be able to deposit/pause/resume the subscriptions for each provider separately.
 * Currently, we deposit/pause the subscriptions for all providers in a single function.
 * We can manage the balance & active status for each provider separately so that the subscribers can continue using the services only which they like.
 *
 * 3. Introduce different fees for each plan.
 * Currently, the `plan` field of the Provider does not have any effect on the smart contract level.
 * We can introduce different fees for each plan, just like the real-case scenario.
 *
 */
contract SubscriptionManager is Ownable, AutomationCompatibleInterface {
    /// @dev Thrown when the caller is not the Provider's owner.
    error CallerNotProviderOwner(address caller);

    /// @dev Thrown when the caller is not the subscription owner.
    error CallerNotSubscriptionOwner(address caller);

    /// @dev Thrown when trying to register a Provider with an invalid fee amount.
    error InvalidProviderFee(uint feeAmount);

    /// @dev Thrown when trying to register a Provider with a key that has already been used.
    error ProviderRegKeyAlreadyUsed(bytes32 regKey);

    /// @dev Thrown when the number of Providers reached the maximum limit.
    error NumberOfProvidersReachedMaximumLimit(uint maxLimit);

    /// @dev Thrown when the Provider id is invalid.
    error InvalidProviderId(uint providerId);

    /// @dev Thrown when the lengths of two input arrays do not match with each other.
    error MismatchingInputArrays(uint len1, uint len2);

    /// @dev Thrown when the input array is empty.
    error EmptyArrayNotAllowed();

    /// @dev Thrown when the Provider is not active.
    error ProviderInactive(uint providerId);

    /// @dev Thrown when the Subscriber's deposit amount is not enough for registration.
    error InsufficientDeposit(uint depositAmount, uint minAmount);

    /// @dev Thrown when the Subscriber is not active.
    error SubscriberInactive(uint subscriberId);

    /// @notice Triggered when a new Provider has been registered.
    event ProviderRegistered(
        uint indexed providerId,
        address indexed owner,
        bytes32 regKey,
        uint fee
    );

    /// @notice Triggered when a Provider has been removed.
    event ProviderRemoved(uint indexed providerId);

    /// @notice Triggered when a new Subscriber has been registered.
    event SubscriberRegistered(
        uint indexed subscriberId,
        address indexed owner,
        uint depositAmount
    );

    /// @notice Triggered when a Provider's earnings have been withdrawn.
    event ProviderEarningsWithdrawn(
        uint indexed providerId,
        address indexed owner,
        uint amount,
        uint timestamp
    );

    /// @notice Enum for the subscription plans.
    enum SubscriptionPlan {
        Silver,
        Gold,
        Platinum
    }

    /// @notice Struct representing a Provider entity, who provides services to its subscribers.
    struct Provider {
        address owner; // Address of the owner, who can remove the Provider or withdraw the earnings.
        bool active; // Indicates whether the Provider currently provides services or not.
        bytes32 regKey; // Registration key
        uint fee; // Fee that the Provider charges its subscribers periodically, e.g., once a month.
        uint balance; // Remaining balance
        uint[] subscriberIds; // ID array of the subscribers who subscribed to this service.
    }

    /// @notice Struct representing a Subscriber entity, who use the services and pay the fees.
    struct Subscriber {
        address owner; // Address of the owner, who can pause the subscription.
        bool active; // Indicates whether the subscription is active or not.
        /**
         * @notice Subscription plan.
         * @dev Currently, it does not affect the cost of the subscription.
         */
        SubscriptionPlan plan;
        uint balance; // Remaining balance
        uint lastSettlementTime; // Last timestamp at which the fees were settled.
        uint[] providerIds; // ID array of the providers that provides services for this subscriber.
    }

    /// @notice Payment token, used as a medium of payment between Providers and Subscribers.
    IERC20 immutable paymentToken;
    /// @notice Maximum limit on the number of Providers.
    uint public constant MAX_NUMBER_OF_PROVIDERS = 200;
    /// @notice Duration of 1 epoch.
    uint public constant EPOCH_LENGTH = 30 days;

    /// @notice ID of the last registered Provider.
    uint lastProviderId;
    /// @notice ID of the last registered Subscriber.
    uint lastSubscriberId;

    /**
     * @notice A mapping of all Providers registered to the system.
     * @dev Better to use a mapping than an array as we need to be able to remove the Providers
     * and we don't need to iterate through all providers.
     */
    mapping(uint => Provider) providers;
    /// @notice A mapping which indicates whether a Provider registration key has already been used.
    mapping(bytes32 => bool) private regKeysUsed;
    /// @notice Array of all Subscribers registered to the system.
    Subscriber[] subscribers;

    constructor(address paymentTokenAddr) Ownable(msg.sender) {
        paymentToken = IERC20(paymentTokenAddr);
    }

    /**
     * @dev Throws if called by any account other than the Provider owner.
     */
    modifier onlyProviderOwner(uint providerId) {
        if (msg.sender != providers[providerId].owner) {
            revert CallerNotProviderOwner(msg.sender);
        }
        _;
    }

    /**
     * @dev Throws if called by any account other than the Subscriber owner.
     */
    modifier onlySubscriberOwner(uint subscriberId) {
        if (msg.sender != subscribers[subscriberId].owner) {
            revert CallerNotSubscriptionOwner(msg.sender);
        }
        _;
    }

    /**
     * @notice Registers a new Provider.
     * @dev Currently, it is 30 days, which means that the subscribers are charged the fees once a month.
     * We can change this to a week, a day or even an hour, according to our need.
     */
    function registerProvider(
        bytes32 regKey,
        uint fee
    ) external returns (uint) {
        if (fee == 0) revert InvalidProviderFee(fee);
        if (lastProviderId >= MAX_NUMBER_OF_PROVIDERS)
            revert NumberOfProvidersReachedMaximumLimit(
                MAX_NUMBER_OF_PROVIDERS
            );
        if (regKeysUsed[regKey]) revert ProviderRegKeyAlreadyUsed(regKey);

        uint providerId = ++lastProviderId;

        uint[] memory emptySubscriberIds;
        providers[providerId] = Provider({
            owner: msg.sender,
            regKey: regKey,
            fee: fee,
            balance: 0,
            active: true,
            subscriberIds: emptySubscriberIds
        });

        regKeysUsed[regKey] = true;
        emit ProviderRegistered(providerId, msg.sender, regKey, fee);
        return providerId;
    }

    /**
     * @notice Removes a Provider.
     * @dev Can only be called by the Provider owner.
     */
    function removeProvider(
        uint providerId
    ) external onlyProviderOwner(providerId) {
        // Transfer the provider's remaining balance to the owner.
        withdrawProviderEarnings(providerId);
        // Delete the provider from the storage.
        delete providers[providerId];

        emit ProviderRemoved(providerId);
    }

    /**
     * @notice Registers a new Subscriber.
     * @dev The Subscriber has to deposit funds into the contract, which should cover at least two epochs' worth of provider fees.
     */
    function registerSubscriber(
        uint depositAmount,
        SubscriptionPlan subscriptionPlan,
        uint[] calldata providerIds
    ) external {
        if (providerIds.length == 0) revert EmptyArrayNotAllowed();
        uint subscriberId = ++lastSubscriberId;

        // Calculate the sum of provider fees for 1 epoch.
        uint totalFees = 0;
        for (uint i = 0; i < providerIds.length; i++) {
            uint providerId = providerIds[i];
            Provider storage provider = providers[providerId];

            // Only allow subscriptions to active providers
            if (!provider.active) revert ProviderInactive(providerId);

            provider.subscriberIds.push(subscriberId);
            provider.balance += provider.fee;
            totalFees += provider.fee;
        }

        // Revert if the deposit amount is not enough to cover two epochs' worth of provider fees.
        if (depositAmount < totalFees * 2)
            revert InsufficientDeposit(depositAmount, totalFees * 2);

        subscribers[subscriberId] = Subscriber({
            owner: msg.sender,
            plan: subscriptionPlan,
            providerIds: providerIds,
            balance: depositAmount - totalFees, // Fees for the first epoch are deducted.
            lastSettlementTime: block.timestamp,
            active: true
        });

        // Deposit the funds
        paymentToken.transferFrom(msg.sender, address(this), depositAmount);

        emit SubscriberRegistered(subscriberId, msg.sender, depositAmount);
    }

    /**
     * @notice Pauses a subscription.
     * @dev Can only be called by the Subscriber owner.
     */
    function pauseSubscription(
        uint subscriberId
    ) external onlySubscriberOwner(subscriberId) {
        Subscriber storage subscriber = subscribers[subscriberId];
        if (subscriber.active) revert SubscriberInactive(subscriberId);

        subscriber.active = false;

        for (uint i = 0; i < subscriber.providerIds.length; i++) {
            uint providerId = subscriber.providerIds[i];
            Provider storage provider = providers[providerId];

            // Remove the subscriber from the provider's subscribers list
            uint[] storage subscriberList = provider.subscriberIds;
            for (uint j = 0; j < subscriberList.length; j++) {
                if (subscriberList[j] == subscriberId) {
                    // Swap the found subscriber ID with the last one in the array, then delete the last one
                    subscriberList[j] = subscriberList[
                        subscriberList.length - 1
                    ];
                    subscriberList.pop();
                    break;
                }
            }
        }
    }

    /**
     * @notice Increase the subscription deposit.
     */
    function depositForSubscription(uint subscriberId, uint amount) external {
        subscribers[subscriberId].balance += amount;
        paymentToken.transferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Withdraw provider's earnings.
     * @dev Can only be called by the Provider owner.
     */
    function withdrawProviderEarnings(
        uint providerId
    ) public onlyProviderOwner(providerId) {
        uint balanceToWithdraw = providers[providerId].balance;
        providers[providerId].balance = 0;
        paymentToken.transfer(msg.sender, balanceToWithdraw);

        emit ProviderEarningsWithdrawn(
            providerId,
            msg.sender,
            balanceToWithdraw,
            block.timestamp
        );
    }

    /**
     * @notice Update the providers' states (active or inactive).
     * @dev Can only be called by the contract owner.
     */
    function updateProvidersState(
        uint[] calldata providerIds,
        bool[] calldata activeFlags
    ) external onlyOwner {
        if (providerIds.length != activeFlags.length)
            revert MismatchingInputArrays(
                providerIds.length,
                activeFlags.length
            );

        for (uint i = 0; i < providerIds.length; i++) {
            uint providerId = providerIds[i];
            if (providerId > lastProviderId)
                revert InvalidProviderId(providerId);

            providers[providerIds[i]].active = activeFlags[i];
        }
    }

    /**
     * @notice Overridden method of the AutomationCompatibleInterface interface.
     * @dev Called periodically by the Chainlink automation keeper.
     * As this is a view function, it doesn't cost any gas fees.
     * We should do as much computation we need as possible here to reduce the gas fees for running performUpkeep.
     * @return upkeepNeeded boolean to indicate whether the keeper should call performUpkeep or not.
     * True when there are any active subscribers who are due to payment.
     * @return performData bytes that the keeper should call performUpkeep with, if `upkeepNeeded` is true.
     * An encoded array of subscriber ids who are active and due to payment.
     */
    function checkUpkeep(
        bytes calldata /*checkData*/
    )
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        uint unsettledSubscriberCount = 0;
        // Get the total number of subscribers who are active and have not paid the fees for at least 1 epoch.
        for (uint i = 0; i < subscribers.length; i++) {
            Subscriber storage subscriber = subscribers[i];
            if (!subscriber.active) continue;

            uint unsettledEpochs = (block.timestamp -
                subscriber.lastSettlementTime) / EPOCH_LENGTH;
            if (unsettledEpochs == 0) continue;

            unsettledSubscriberCount++;
        }

        // If there are not unsettled subscribers, we don't need to call the `performUpkeep` function.
        if (unsettledSubscriberCount == 0) return (false, "");

        // Iterate through the subscribers list again and compose the list of unsettled subscribers.
        uint[] memory unsettledSubscribers = new uint[](
            unsettledSubscriberCount
        );
        for (uint i = 0; i < subscribers.length; i++) {
            Subscriber storage subscriber = subscribers[i];
            if (!subscriber.active) continue;

            uint unsettledEpochs = (block.timestamp -
                subscriber.lastSettlementTime) / EPOCH_LENGTH;
            if (unsettledEpochs == 0) continue;

            unsettledSubscribers[unsettledSubscriberCount++] = i;
        }

        return (true, abi.encode(unsettledSubscribers));
    }

    /**
     * @notice Overridden method of the AutomationCompatibleInterface interface.
     * @dev Called by the Chainlink automation keeper if the `checkUpkeep` function returns true.
     * @param performData Data passed in from the `checkUpkeep` function.
     * An encoded array of subscriber ids who are active and due to payment.
     */
    function performUpkeep(bytes calldata performData) external override {
        // Decode the array of unsettled subscribers.
        uint[] memory unsettledSubscribers = abi.decode(performData, (uint[]));

        for (uint i = 0; i < unsettledSubscribers.length; i++) {
            settleSubscriptionFee(unsettledSubscribers[i]);
        }
    }

    /**
     * @notice Settles the fees for a Subscriber.
     * @dev Deducts the fees from the Subscriber and adds it to the Provider.
     *
     */
    function settleSubscriptionFee(uint subscriberId) private {
        Subscriber storage subscriber = subscribers[subscriberId];
        if (!subscriber.active) return;

        uint unsettledEpochs = (block.timestamp -
            subscriber.lastSettlementTime) / EPOCH_LENGTH;
        if (unsettledEpochs == 0) return;

        uint providerIdsLen = subscriber.providerIds.length;
        uint[] memory unsettledFees = new uint[](providerIdsLen);
        uint totalUnsettledFees = 0;

        // Calculate the total amount of fees to settle.
        for (uint i = 0; i < providerIdsLen; i++) {
            uint providerId = subscriber.providerIds[i];
            Provider storage provider = providers[providerId];
            if (!provider.active) continue;

            uint unsettledFee = provider.fee * unsettledEpochs;
            unsettledFees[i] = unsettledFee;
            totalUnsettledFees += unsettledFee;
        }

        // If the subscriber's balance is not enough to pay the fees, pause the subscription and return.
        if (subscriber.balance < totalUnsettledFees) {
            subscriber.active = false;
            return;
        }

        // Transfer fees from the subscriber to providers.
        subscriber.balance -= totalUnsettledFees;
        for (uint i = 0; i < providerIdsLen; i++) {
            if (unsettledFees[i] > 0) {
                uint providerId = subscriber.providerIds[i];
                providers[providerId].balance += unsettledFees[i];
            }
        }

        // Update the lastSettlementTime
        subscriber.lastSettlementTime = block.timestamp;
    }

    /**
     * @notice Get the state of a provider by id: returns number of subscribers, fee, owner, balance, and state.
     */
    function getProviderState(
        uint providerId
    ) public view returns (uint, uint, address, uint, bool) {
        Provider storage provider = providers[providerId];
        return (
            provider.subscriberIds.length,
            provider.fee,
            provider.owner,
            provider.balance,
            provider.active
        );
    }

    /**
     * @notice Get the provider earnings by id.
     */
    function getProviderEarnings(uint providerId) public view returns (uint) {
        return providers[providerId].balance;
    }

    /**
     * @notice Get the state of a subscriber by id: owner, balance, plan, and state
     */
    function getSubscriberState(
        uint subscriberId
    ) public view returns (address, uint, SubscriptionPlan, bool) {
        Subscriber memory subscriber = subscribers[subscriberId];
        return (
            subscriber.owner,
            subscriber.balance,
            subscriber.plan,
            subscriber.active
        );
    }

    /**
     * @notice Get the live balance of a subscriber.
     * @dev As all the fees are pre-paid, just return the remaining balance.
     */
    function getSubscriberLiveBalance(
        uint subscriberId
    ) public view returns (uint) {
        return subscribers[subscriberId].balance;
    }
}
