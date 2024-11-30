module livtorgex::strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::bcs;
    use std::error;
    use std::type_info;

    use aptos_framework::coin;
    use aptos_framework::object::{Self, TransferRef, Object};
    use aptos_framework::timestamp;
    use aptos_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::aptos_account;

    use aptos_token_objects::token::{Token};
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use aptos_token_objects::royalty;

    use livtorgex::strategy_events;


    const LIVTORGEX_FEE_ADDRESS: address = @0xed7f2163f999e4aa5658f56e457b1bc4a293a6d4050aa07e81345674b63e39af;
    /// Min 10% fee for platform usage
    /// Fee can be adjusted more for some specific collection and better support of the platform
    const LIVTORGEX_MIN_FEE: u64 = 100000000 / 10;

    // NFT_DENOMINATOR and OCTAS_PER_APTOS has same precision.
    const NFT_DENOMINATOR: u64 = 100000000;
    const NFT_MAX_ENERGY: u64 = 10000000000;

    /// Strategy doesn't exist at this address
    const ESTRATEGY_NOT_EXIST: u64 = 0;
    /// This account doesn't have access to strategy
    const EACCESS_DENIEND: u64 = 1;
    /// The owner must own the token to transfer it
    const ENOT_TOKEN_OWNER: u64 = 2;
    /// The owner of the token
    const ETOKEN_IN_LOCKUP: u64 = 3;
    /// Unsupported coin type
    const EUNSUPPORTED_COIN_TYPE: u64 = 4;
    /// NFT not borrowed yet
    const ENFT_NOT_BORROW: u64 = 12;
    /// NFT already borrowed
    const ENFT_BORROWED: u64 = 13;
    /// NFT not activated yet
    const ENFT_NOT_ACTIVE: u64 = 14;
    /// NFT already activated
    const ENFT_ACTIVED: u64 = 15;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Strategy has key {
        name: String,
        // TODO: Add profit sharing for DAO system
        // The signer capability for the resource account where the Strategy is hosted (aka the Strategy account).
        strategy_signer_capability: SignerCapability,
        // The address of the Strategy's owner who has certain permissions over the Strategy.
        // This can be set to 0x0 to remove all owner powers.
        owner: address,
        // The pending claims waiting for new owner to claim
        pending_owner: Option<address>
    }

    #[event]
    struct CreateStrategy has drop, store {
        nft_strategy: address,
        name: String,
        owner: address
    }

    // Struct to save NFT with precision 0.00001
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StrategyNFT has key {
        company_name: String,
        energy: u64,
        profit: u64,
        volume: u64,
        k_refill: u64,
        k_profit: u64,
        k_volume: u64,
        k_time: u64,
        borrow: Option<address>,
        updated_at: u64,
        mutator_ref: token::MutatorRef
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StrategyNFTLockup has key {
        is_active: bool,
        is_borrowed: bool,
        transfer_ref: TransferRef
    }

    //////////////////// All view functions ////////////////////////////////
    #[view]
    public fun get_nft_energy(strategy_addr: address, name: String): u64 acquires Strategy, StrategyNFT {
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_address = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global<StrategyNFT>(nft_address);

        nft.energy
    }

    // Create a new strategy
    public entry fun create_strategy(
        owner: &signer, name: String, description: String, livtorgex_fee: u64
    ) {
        create_strategy_and_get_strategy_address(owner, name, description, livtorgex_fee);
    }

    fun create_strategy_and_get_strategy_address(
        owner: &signer, name: String, description: String, livtorgex_fee: u64,
    ): address {
        // create a resource account
        let seed = bcs::to_bytes(&name);
        let (res_signer, res_cap) = account::create_resource_account(owner, seed);
        let src_addr = signer::address_of(owner);
        let livtorgex_fee = if (livtorgex_fee < LIVTORGEX_MIN_FEE) {
            LIVTORGEX_MIN_FEE
        } else {
            livtorgex_fee
        };
        let royalty = royalty::create(livtorgex_fee, NFT_DENOMINATOR, LIVTORGEX_FEE_ADDRESS);

        // initalize token store and opt-in direct NFT transfer for easy of operation
        aptos_token::token::opt_in_direct_transfer(&res_signer, true);

        collection::create_unlimited_collection(
            &res_signer,
            description,
            name,
            option::some(royalty),
            string::utf8(b"http://livtorgex.com")
        );

        move_to(
            &res_signer,
            Strategy {
                name,
                strategy_signer_capability: res_cap,
                owner: src_addr,
                pending_owner: option::none()
            }
        );

        let nft_strategy = signer::address_of(&res_signer);
        strategy_events::emit_create_strategy(&res_signer, name, src_addr);

        nft_strategy
    }

    // Mint a new NFT
    public entry fun mint_nft(
        account: &signer,
        strategy_addr: address,
        company_name: String,
        name: String,
        description: String,
        uri: String,
        energy: u64,
        k_refill: u64,
        k_profit: u64,
        k_volume: u64,
        k_time: u64
    ) acquires Strategy {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));
        let strategy = borrow_global<Strategy>(strategy_addr);
        let owner_addr = signer::address_of(account);
        let royalty = option::none();

        // Only owner can mint a new access to strategy
        assert!(owner_addr == strategy.owner, error::permission_denied(EACCESS_DENIEND));

        let res_signer =
            create_signer_with_capability(&strategy.strategy_signer_capability);

        let constructor_ref =
            token::create_named_token(
                &res_signer,
                strategy.name,
                description,
                name,
                royalty,
                uri,
            );



        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        let token_signer = object::generate_signer(&constructor_ref);

        // Tranfer token to account
        let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, owner_addr);

        // disable the ability to transfer the token through any means other than the `transfer` function we define
        object::disable_ungated_transfer(&transfer_ref);

        move_to(
            &token_signer,
            StrategyNFT {
                company_name,
                energy,
                profit: 0,
                volume: 0,
                k_refill,
                k_profit,
                k_volume,
                k_time,
                borrow: option::none(),
                updated_at: timestamp::now_seconds(),
                mutator_ref: token::generate_mutator_ref(&constructor_ref)
            }
        );
        move_to(
            &token_signer,
            StrategyNFTLockup { is_active: false, is_borrowed: false, transfer_ref }
        );

        strategy_events::emit_mint_strategy_nft(
            strategy_addr,
            company_name,
            name,
            description,
            energy,
            k_refill,
            k_profit,
            k_volume,
            k_time
        );
    }

    public entry fun transfer(
        from: &signer, token: Object<Token>, to: address
    ) acquires StrategyNFTLockup {
        // redundant error checking for clear error message
        assert!(
            object::is_owner(token, signer::address_of(from)),
            error::permission_denied(ENOT_TOKEN_OWNER)
        );
        let lockup = borrow_global_mut<StrategyNFTLockup>(object::object_address(&token));

        assert!(!lockup.is_borrowed, error::permission_denied(ETOKEN_IN_LOCKUP));
        assert!(!lockup.is_active, error::permission_denied(ETOKEN_IN_LOCKUP));

        // generate linear transfer ref and transfer the token object
        let linear_transfer_ref =
            object::generate_linear_transfer_ref(&lockup.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, to);

    }

    public entry fun borrow_nft(
        account: &signer, token: Object<Token>, borrow_addr: address
    ) acquires StrategyNFT, StrategyNFTLockup {
        let nft_addr = object::object_address(&token);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);
        assert!(option::is_none(&nft.borrow), ENFT_BORROWED);
        assert!(
            object::is_owner(token, signer::address_of(account)),
            error::permission_denied(ENOT_TOKEN_OWNER)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);

        nft.borrow = option::some(borrow_addr);
        lockup.is_borrowed = true;
        strategy_events::emit_borrow_strategy_nft(nft_addr, borrow_addr);
    }

    public entry fun release_nft(
        account: &signer, strategy_addr: address, name: String
    ) acquires Strategy, StrategyNFT, StrategyNFTLockup {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_addr = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);
        assert!(option::is_some(&nft.borrow), ENFT_NOT_BORROW);
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, ENFT_NOT_BORROW);
        assert!(!lockup.is_active, ENFT_ACTIVED);

        nft.borrow = option::none();
        lockup.is_borrowed = false;

        strategy_events::emit_release_strategy_nft(strategy_addr, nft_addr);
    }

    public entry fun start_nft(
        account: &signer, strategy_addr: address, name: String
    ) acquires Strategy, StrategyNFT, StrategyNFTLockup {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_addr = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global<StrategyNFT>(nft_addr);

        assert!(option::is_some(&nft.borrow), ENFT_NOT_BORROW);
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, ENFT_NOT_BORROW);
        assert!(!lockup.is_active, ENFT_ACTIVED);

        lockup.is_active = true;

        strategy_events::emit_start_strategy_nft(strategy_addr, nft_addr);
    }

    public entry fun stop_nft(
        account: &signer, strategy_addr: address, name: String
    ) acquires Strategy, StrategyNFT, StrategyNFTLockup {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_addr = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global<StrategyNFT>(nft_addr);

        assert!(
            option::is_some(&nft.borrow), error::permission_denied(ENFT_NOT_BORROW)
        );
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, error::permission_denied(ENFT_NOT_BORROW));
        assert!(!lockup.is_active, error::permission_denied(ENFT_ACTIVED));

        lockup.is_active = false;

        strategy_events::emit_stop_strategy_nft(strategy_addr, nft_addr);
    }

    // Spend the energy. Should be called from restricted accounts
    public entry fun use_nft_energy(
        account: &signer,
        strategy_addr: address,
        name: String,
        profit: u64,
        volume: u64
    ) acquires Strategy, StrategyNFT, StrategyNFTLockup {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_addr = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);

        assert!(option::is_some(&nft.borrow), ENFT_NOT_BORROW);
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, error::permission_denied(ENFT_NOT_BORROW));

        let energy_usage: u64 = 0;
        let updated_at: u64 = timestamp::now_seconds();

        if (nft.k_profit != 0 && profit != 0) {
            energy_usage = energy_usage + (nft.k_profit * profit) / NFT_DENOMINATOR;
        };

        if (nft.k_volume != 0 && volume != 0) {
            energy_usage = energy_usage + (nft.k_volume * volume) / NFT_DENOMINATOR;
        };

        if (nft.k_time != 0) {
            let time_diff = updated_at - nft.updated_at;
            energy_usage = energy_usage + nft.k_time * ((time_diff / 60) as u64);
        };

        if (energy_usage >= nft.energy) {
            nft.energy = 0;
        } else {
            nft.energy = nft.energy - energy_usage;
        };

        nft.updated_at = updated_at;

        strategy_events::emit_use_strategy_nft(
            strategy_addr,
            nft_addr,
            energy_usage,
            *option::borrow<address>(&nft.borrow)
        );
    }

    // Refill the energy
    // anyone can refill the energy
    public entry fun refill_energy<CoinType>(
        account: &signer,
        strategy_addr: address,
        name: String,
        energy: u64,
    ) acquires Strategy, StrategyNFT {
        assert!(exists<Strategy>(strategy_addr), error::not_found(ESTRATEGY_NOT_EXIST));

        // assert!(is_allowed_coin_type<CoinType>(), error::permission_denied(EUNSUPPORTED_COIN_TYPE));

        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_addr = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);

        let refill_energy =
            if (energy + nft.energy > NFT_MAX_ENERGY) {
                NFT_MAX_ENERGY - nft.energy
            } else { energy };

        // Just to 1to1 rate. Specify any tokens in the is_allowed_coin_type that can use for stable coin
        let price: u64 = nft.k_refill * energy;

        let coins = coin::withdraw<CoinType>(account, price);
        aptos_account::deposit_coins(strategy.owner, coins);

        nft.energy = nft.energy + refill_energy;
    }

    fun is_allowed_coin_type<T>(): bool {
        type_info::type_of<T>() == type_info::type_of<AptosCoin>()
    }

    inline fun get_nft_address(
        creator: &address, collection: &String, name: &String
    ): address {
        token::create_token_address(creator, collection, name)
    }

    #[test(aptos_framework = @0x1, account = @0x3)]
    fun test_nft_creation(aptos_framework: &signer, account: &signer) acquires Strategy, StrategyNFT {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        let company_name = string::utf8(b"LivTorgEx");
        let collection_name = string::utf8(b"SubscriptionCollection");
        let nft_name = string::utf8(b"SubscriptionNFT");
        let description = string::utf8(b"Test NFT for subscription");
        let uri = string::utf8(b"https:://livtorgex.com");

        let energy: u64 = 50 * NFT_DENOMINATOR; // 50.00000
        let k_refill: u64 = 1 * NFT_DENOMINATOR; // 1.00000 (100% refill rate)
        let k_profit: u64 = 2_5 * NFT_DENOMINATOR / 100; // 2.50000
        let k_volume: u64 = 0;
        let k_time: u64 = 0;

        let strategy_addr =
            create_strategy_and_get_strategy_address(
                account, collection_name, description, 10 * NFT_DENOMINATOR
            );
        mint_nft(
            account,
            strategy_addr,
            company_name,
            nft_name,
            description,
            uri,
            energy,
            k_refill,
            k_profit,
            k_volume,
            k_time
        );

        let nft_address = get_nft_address(&strategy_addr, &collection_name, &nft_name);
        let nft = borrow_global<StrategyNFT>(nft_address);

        assert!(nft.energy == energy, 100);
        assert!(nft.k_refill == k_refill, 101);
        assert!(nft.k_profit == k_profit, 102);
        assert!(nft.k_volume == k_volume, 103);
        assert!(nft.k_time == k_time, 104);
    }

    // #[test]
    // public fun test_use_energy(account: &signer) {
    //     let collection_name = "SubscriptionCollection";
    //     let nft_name = "SubscriptionNFT";
    //     let description = "Test NFT for subscription";
    //     let energy: u64 = 50_00000; // 50.00000
    //     let refill: u64 = 1_00000;  // 1.00000 (100% refill rate)
    //     let profit: u64 = 2_50000;  // 2.50000
    //     let volume: u64 = 3_00000;  // 3.00000
    //     let time: u64 = 4_00000;    // 4.00000

    //     let nft_id = mint_nft(account, collection_name, nft_name, description, energy, refill, profit, volume, time);

    //     use_energy(account, &nft_id, 10_00000, 0, 5_00000);

    //     let nft = borrow_global<SubscriptionNft>(&nft_id);
    //     assert!(nft.energy < 50_00000, 105);
    // }

    // #[test]
    // public fun test_refill_energy(account: &signer) {
    //     let collection_name = "SubscriptionCollection";
    //     let nft_name = "SubscriptionNFT";
    //     let description = "Test NFT for subscription";
    //     let energy: u64 = 20_00000; // 20.00000
    //     let refill: u64 = 1_00000;  // 1.00000 (100% refill rate)
    //     let profit: u64 = 2_50000;  // 2.50000
    //     let volume: u64 = 3_00000;  // 3.00000
    //     let time: u64 = 4_00000;    // 4.00000

    //     let nft_id = mint_nft(account, collection_name, nft_name, description, energy, refill, profit, volume, time);

    //     refill_energy(account, &nft_id);

    //     let nft = borrow_global<SubscriptionNft>(&nft_id);
    //     assert!(nft.energy == 100_00000, 106);
    // }
}
