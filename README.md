# PROVIDER-SUBSCRIBER-CONTRACTS

Smart contracts for a Provider-Subscriber system, where Providers offer some services for a monthly fee and these services are consumed by Subscribers.

## Things to note:

**1. In the code, `epoch` means one billing cycle.**

    Currently, it is set to 1 month.
    This can be changed to 1 week or 1 day, according to our needs, by changing the value of the `EPOCH_LENGTH` constant.

**2. In order to make the billing process fair and reliable, we use the Prepaid Subscription plan.**

    Subscribers have to pay the fee for the first epoch when they start using a Provider's service.
    They can use the service for 1 epoch, and then at the end of the epoch, they have to pay the fee again to continue using the service.
    If a subscriber doesn't have enough funds to pay the fees, his subscription is automatically paused.

    - Benefits over Postpaid Subscription plan:

      - Guarantees that the providers always get paid for their services.
        If we use the Postpaid Subscription, there is no guarantee that the subscriber would deposit funds until the end of an epoch.

      - Enables us to change the provider fees in the middle of an epoch.
        We just need to update the `fee` field of the Provider, and this change will come into effect from the next epoch.
        Subscribers can see this change, and if the fee is unacceptable, they can pause the subscription.
      - Makes the billing process simpler and more straightforward.

**3. We use the Chainlink automation to check periodically(e.g., daily) if there are any subscribers due to payment.**

**4. I used the `uint256` type for Provider ID for the system scalability.**

    If we are gonna stick with the restriction of the maximum number of providers to 200, we can use a Byte for it.
    So, instead of `uint[]`, we can use `bytes` for `providerIds` array to save the storage cost.

## Suggestions for further improvements:

**1. Separate the subscriber registration and subscription.**

    Currently, we ask the subscribers to specify which Providers they want to subscribe to at the point of registration,
    and they cannot change it afterward.
    We can add separate functions for registration and subscription, so that the subscribers can subscribe to any Providers they want at any time.

**2. Let the subscribers be able to deposit/pause/resume the subscriptions for each provider separately.**

    Currently, we deposit/pause the subscriptions for all providers in a single function.
    We can manage the balance & active status for each provider separately so that the subscribers can continue using the services only which they like.

**3. Introduce different fees for each plan.**

    Currently, the `plan` field of the Provider does not have any effect on the smart contract level.
    We can introduce different fees for each plan, just like the real-case scenario.
