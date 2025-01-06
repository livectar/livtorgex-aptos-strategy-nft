module livtorgex::strategy {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::bcs;
    use std::error;
    use std::vector;
    use std::string_utils;

    use aptos_std::math64;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account::{
        Self,
        SignerCapability,
        create_signer_with_capability,
        create_resource_address
    };
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;

    use aptos_token_objects::token::{Self, Token, collection_object};
    use aptos_token_objects::collection;
    use aptos_token_objects::royalty;

    use livtorgex::strategy_events;

    // Meta information
    const STRATEGY_VERSION_NAME: vector<u8> = b"Profit Sharing v1";

    const PAYMENT_COINS: vector<address> = vector[@stablecoin];
    // Use denomitator with 6 Decimals for stablecoin
    /// Min 20% fee for platform usage
    /// Fee can be adjusted more for some specific collection and better support of the platform
    const LIVTORGEX_MIN_FEE: u64 = 200000;

    // NFT_PRECISION and OCTAS_PER_APTOS has same precision.
    const NFT_REFILL_DENOMINATOR: u64 = 1000000;
    const NFT_PRECISION: u64 = 100000000;
    const NFT_MAX_ENERGY: u64 = 100000000 * 100;

    // Trade Mode
    const NFT_TRADE_SIMULATION: u64 = 0;
    const NFT_TRADE_EXCHANGE: u64 = 1;

    // NFT Role
    const NFT_ROLE_INDIVIDUAL: u64 = 0;
    const NFT_ROLE_COMPANY: u64 = 1;

    // NFT Energy Refill Capacity Request
    const NFT_ENERGY_REFILL_CAPACITY_REQUEST_ADD: u64 = 0;
    const NFT_ENERGY_REFILL_CAPACITY_REQUEST_SUBTRACT: u64 = 1;

    // Request Status
    const REQUEST_STATUS_REJECT: u64 = 0;
    const REQUEST_STATUS_APPROVE: u64 = 1;

    /// Strategy doesn't exist
    const ESTRATEGY_NOT_EXIST: u64 = 0;
    /// Strategy already exist
    const ESTRATEGY_ALREADY_EXIST: u64 = 1;
    /// This account doesn't have access to strategy
    const EACCESS_DENIEND: u64 = 2;
    /// The owner must own the token to transfer it
    const ENOT_TOKEN_OWNER: u64 = 3;
    /// The owner of the token
    const ETOKEN_IN_LOCKUP: u64 = 4;
    /// Unsupported coin type
    const EUNSUPPORTED_COIN_TYPE: u64 = 5;
    /// Invalid owner account
    const EINVALID_OWNER_ACCOUNT: u64 = 6;
    /// Strategy already offered for the new owner
    const EOWNER_ALREADY_OFFERED: u64 = 7;
    /// Strategy offer doesn't exist
    const EOWNER_OFFER_NOT_EXIST: u64 = 8;
    /// Strategy already offered for the new fee
    const ELIVTORGEX_ALREADY_EXISTS: u64 = 9;
    /// Strategy LivTorgEx change doesn't exist
    const ELIVTORGEX_CHANGE_NOT_EXIST: u64 = 10;
    /// NFT not borrowed yet
    const ENFT_NOT_BORROW: u64 = 100;
    /// NFT already borrowed
    const ENFT_BORROWED: u64 = 101;
    /// NFT energy full
    const ENFT_ENERGY_FULL: u64 = 102;
    /// NFT refill should use only stablecoins
    const ENFT_NOT_STABLECOIN: u64 = 103;
    /// NFT does not have enough capacity to replenish energy
    const ENFT_NOT_ENERGY_REFILL_CAPACITY: u64 = 104;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Management has key {
        owner: address,
        signer_capability: SignerCapability
    }

    // Profit sharing will go to account that will be borrowed to run the bot
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Strategy has key {
        name: String,
        version: String,
        livtorgex_fee: u64,
        livtorgex_owner: address,
        pending_livtorgex_fee: Option<u64>,
        // The signer capability for the resource account where the Strategy is hosted (aka the Strategy account).
        strategy_signer_capability: SignerCapability,
        // List of coins that may be used to pay for the fee. Owner can change it later.
        payment_coins: vector<address>,
        // The address of the Strategy's owner who has certain permissions over the Strategy.
        // This can be set to 0x0 to remove all owner powers.
        owner: address,
        // The pending claims waiting for new owner to claim
        pending_owner: Option<address>,
        // Count for minted tokens. Usage for adding token number into the NFT name
        total_minted: u64
    }

    // Struct to save NFT with precision 0.00001
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StrategyNFT has key {
        company_code: String,
        trade_mode: u64,
        role: u64,
        energy: u64,
        energy_refill_capacity: u64,
        profit: u64,
        k_refill: u64,
        k_profit: u64,
        borrow: Option<address>
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct StrategyNFTLockup has key, drop {
        is_borrowed: bool,
        transfer_ref: object::TransferRef,
        mutator_ref: token::MutatorRef,
        burn_ref: token::BurnRef
    }

    //////////////////// All view functions ////////////////////////////////
    #[view]
    public fun get_nft_energy(strategy_addr: address, name: String): u64 acquires Strategy, StrategyNFT {
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft_address = get_nft_address(&strategy_addr, &strategy.name, &name);
        let nft = borrow_global<StrategyNFT>(nft_address);

        nft.energy
    }

    #[view]
    public fun get_strategy_address(name: String): address acquires Management {
        let manager = borrow_global<Management>(@livtorgex);

        let seed = bcs::to_bytes(&name);
        let strategy_addr = create_resource_address(&manager.owner, seed);
        // TODO: provide error if not exists. Need to fix it somehow
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        strategy_addr
    }

    #[view]
    public fun unpack_strategy(
        name: String
    ): (address, String, String, u64, vector<address>, u64) acquires Management, Strategy {
        let manager = borrow_global<Management>(@livtorgex);

        let seed = bcs::to_bytes(&name);
        let strategy_addr = create_resource_address(&manager.owner, seed);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let strategy = borrow_global<Strategy>(strategy_addr);

        (
            strategy_addr,
            strategy.name,
            strategy.version,
            strategy.livtorgex_fee,
            strategy.payment_coins,
            strategy.total_minted
        )
    }

    #[view]
    public fun unpack_nft_properties(
        token: Object<Token>
    ): (String, u64, u64, u64, u64, u64, bool) acquires StrategyNFT, StrategyNFTLockup {
        let nft_address = object::object_address(&token);
        let nft = borrow_global<StrategyNFT>(nft_address);
        let nft_lockup = borrow_global<StrategyNFTLockup>(nft_address);

        (
            nft.company_code,
            nft.trade_mode,
            nft.role,
            nft.energy,
            nft.k_refill,
            nft.k_profit,
            nft_lockup.is_borrowed
        )
    }

    fun init_module(owner: &signer) {
        let (res_signer, res_cap) =
            account::create_resource_account(owner, STRATEGY_VERSION_NAME);
        move_to(
            owner,
            Management {
                owner: signer::address_of(&res_signer),
                signer_capability: res_cap
            }
        );
    }

    // Create a new strategy
    public entry fun create_strategy(
        owner: &signer,
        name: String,
        description: String,
        uri: String,
        livtorgex_fee: u64,
        livtorgex_owner: address
    ) acquires Management {
        create_strategy_and_get_strategy_address(
            owner,
            name,
            description,
            uri,
            livtorgex_fee,
            livtorgex_owner
        );
    }

    fun create_strategy_and_get_strategy_address(
        owner: &signer,
        name: String,
        description: String,
        uri: String,
        livtorgex_fee: u64,
        livtorgex_owner: address
    ): address acquires Management {
        let manager = borrow_global<Management>(@livtorgex);
        let manager_signer = create_signer_with_capability(&manager.signer_capability);

        // create a resource account
        let seed = bcs::to_bytes(&name);
        let strategy_addr = create_resource_address(&manager.owner, seed);
        assert!(!exists<Strategy>(strategy_addr), ESTRATEGY_ALREADY_EXIST);

        let (res_signer, res_cap) =
            account::create_resource_account(&manager_signer, seed);
        let src_addr = signer::address_of(owner);

        move_to(
            &res_signer,
            Strategy {
                name,
                version: string::utf8(STRATEGY_VERSION_NAME),
                strategy_signer_capability: res_cap,
                livtorgex_fee,
                livtorgex_owner,
                pending_livtorgex_fee: option::none(),
                payment_coins: PAYMENT_COINS,
                owner: src_addr,
                pending_owner: option::none(),
                total_minted: 0
            }
        );

        strategy_events::emit_create_strategy(strategy_addr, name, src_addr);

        // initalize token store and opt-in direct NFT transfer for easy of operation
        aptos_token::token::opt_in_direct_transfer(&res_signer, true);

        collection::create_unlimited_collection(
            &res_signer,
            description,
            name,
            option::none(),
            uri
        );

        strategy_addr
    }

    /// Offer owner of a Stategy to an new owner. The new owner can then claim the offer to be the new owner of the Strategy.
    public entry fun strategy_offer_owner(
        owner: &signer, strategy_addr: address, new_owner: address
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );

        assert!(
            option::is_none(&strategy.pending_owner),
            error::invalid_argument(EOWNER_ALREADY_OFFERED)
        );
        option::fill(&mut strategy.pending_owner, new_owner);
        strategy_events::emit_strategy_owner_offer_event(
            owner_addr, new_owner, strategy_addr
        );
    }

    /// Cancel the strategy owner offer
    public entry fun strategy_cancel_owner_offer(
        owner: &signer, strategy_addr: address
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );
        // Strategy offer exists
        assert!(
            option::is_some(&strategy.pending_owner),
            error::invalid_argument(EOWNER_OFFER_NOT_EXIST)
        );
        option::extract(&mut strategy.pending_owner);
        strategy_events::emit_strategy_owner_offer_cancel_event(
            owner_addr, strategy_addr
        );
    }

    /// Claim Strategy owner from an offer. The owner will become the owner of the Strategy.
    public entry fun strategy_claim_owner(
        account: &signer, strategy_addr: address
    ) acquires Strategy {
        // Strategy offer exists
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            option::is_some(&strategy.pending_owner),
            error::invalid_argument(EOWNER_OFFER_NOT_EXIST)
        );

        // Allow setting the owner to 0x0.
        let new_owner = option::extract(&mut strategy.pending_owner);
        let old_owner = strategy.owner;
        let caller_address = signer::address_of(account);
        if (new_owner == @0x0) {
            // If the owner is being updated to 0x0, for security reasons, this finalization must only be done by the
            // current owner.
            assert!(
                old_owner == caller_address,
                error::permission_denied(EINVALID_OWNER_ACCOUNT)
            );
        } else {
            // Otherwise, only the new owner can finalize the transfer.
            assert!(
                new_owner == caller_address, error::not_found(EOWNER_OFFER_NOT_EXIST)
            );
        };

        // update the Strategy's owner address
        strategy.owner = new_owner;
        strategy_events::emit_strategy_owner_claim_event(
            old_owner, new_owner, strategy_addr
        );
    }

    /// Change payment coins for the strategy.
    public entry fun strategy_change_payment_coins(
        owner: &signer, strategy_addr: address, payment_coins: vector<address>
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.livtorgex_owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );

        strategy.payment_coins = payment_coins;

        strategy_events::emit_strategy_change_payment_coins_event(
            owner_addr, payment_coins, strategy_addr
        );
    }

    /// Change owner of LivTorgEx ownership.
    public entry fun strategy_change_livtorgex_address(
        owner: &signer, strategy_addr: address, new_owner: address
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.livtorgex_owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );

        strategy.livtorgex_owner = new_owner;

        strategy_events::emit_strategy_change_livtorgex_address_event(
            owner_addr, new_owner, strategy_addr
        );
    }

    /// Offer a new changes for LivTorgEx.
    public entry fun strategy_request_livtorgex(
        owner: &signer, strategy_addr: address, new_fee: u64
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.livtorgex_owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );

        assert!(
            option::is_none(&strategy.pending_livtorgex_fee),
            error::invalid_argument(ELIVTORGEX_ALREADY_EXISTS)
        );
        option::fill(&mut strategy.pending_livtorgex_fee, new_fee);
        strategy_events::emit_strategy_request_livtorgex_event(
            owner_addr, new_fee, strategy_addr
        );
    }

    /// Cancel the strategy request for livtorgex
    public entry fun strategy_resolve_livtorgex(
        owner: &signer, strategy_addr: address, status: u64
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let owner_addr = signer::address_of(owner);
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        assert!(
            owner_addr == strategy.owner,
            error::permission_denied(EINVALID_OWNER_ACCOUNT)
        );
        // Strategy offer exists
        assert!(
            option::is_some(&strategy.pending_livtorgex_fee),
            error::invalid_argument(ELIVTORGEX_CHANGE_NOT_EXIST)
        );
        if (status == REQUEST_STATUS_REJECT) {
            option::extract(&mut strategy.pending_livtorgex_fee);
        };
        if (status == REQUEST_STATUS_APPROVE) {
            let new_fee = option::extract(&mut strategy.pending_livtorgex_fee);
            strategy.livtorgex_fee = new_fee;
        };
        strategy_events::emit_strategy_resolve_livtorgex_event(
            owner_addr, status, strategy_addr
        );
    }

    // Allow to mint NFT for strategy
    public entry fun mint_nfts(
        account: &signer,
        strategy_addr: address,
        company_code: String,
        trade_mode: u64,
        role: u64,
        description: String,
        name: String,
        size: u64,
        uri: String,
        energy: u64,
        energy_refill_capacity: u64,
        k_refill: u64,
        k_profit: u64,
        community_address: Option<address>,
        community_fee: Option<u64>
    ) acquires Strategy {
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let strategy = borrow_global_mut<Strategy>(strategy_addr);
        let owner_addr = signer::address_of(account);

        // Only owner can mint a new access to strategy
        assert!(owner_addr == strategy.owner, error::permission_denied(EACCESS_DENIEND));

        let royalty =
            if (option::is_some(&community_address) && option::is_some(&community_fee)) {
                option::some(
                    royalty::create(
                        *option::borrow<u64>(&community_fee),
                        NFT_REFILL_DENOMINATOR,
                        *option::borrow<address>(&community_address)
                    )
                )
            } else {
                option::none()
            };

        let res_signer =
            create_signer_with_capability(&strategy.strategy_signer_capability);

        for (i in 0..size) {
            let suffix = string::utf8(b" #");
            let index_str = string_utils::to_string(&(strategy.total_minted + i + 1));
            let nft_name = name;
            string::append(&mut nft_name, suffix);
            string::append(&mut nft_name, index_str);

            let constructor_ref =
                token::create_named_token(
                    &res_signer,
                    strategy.name,
                    description,
                    nft_name,
                    royalty,
                    uri
                );

            let transfer_ref = object::generate_transfer_ref(&constructor_ref);
            let token_signer = object::generate_signer(&constructor_ref);

            // Tranfer token to account
            let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
            object::transfer_with_ref(linear_transfer_ref, owner_addr);

            // disable the ability to transfer the token through any means other than the `transfer` function we define
            // object::enable_ungated_transfer(&transfer_ref);

            move_to(
                &token_signer,
                StrategyNFT {
                    company_code,
                    trade_mode,
                    role,
                    energy,
                    energy_refill_capacity,
                    profit: 0,
                    k_refill,
                    k_profit,
                    borrow: option::none()
                }
            );
            move_to(
                &token_signer,
                StrategyNFTLockup {
                    is_borrowed: false,
                    transfer_ref,
                    mutator_ref: token::generate_mutator_ref(&constructor_ref),
                    burn_ref: token::generate_burn_ref(&constructor_ref)
                }
            );

            strategy_events::emit_mint_strategy_nft(
                strategy_addr,
                company_code,
                name,
                description,
                energy,
                k_refill,
                k_profit
            );
        };

        strategy.total_minted = strategy.total_minted + size;
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

        // generate linear transfer ref and transfer the token object
        let linear_transfer_ref =
            object::generate_linear_transfer_ref(&lockup.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, to);
    }

    public entry fun burn_token(owner: &signer, token: Object<Token>) acquires StrategyNFTLockup {
        // Remove all custom data from the token object.
        let token_address = object::object_address(&token);
        assert!(
            object::is_owner(token, signer::address_of(owner)),
            error::permission_denied(ENOT_TOKEN_OWNER)
        );
        let nft_lockup = borrow_global<StrategyNFTLockup>(token_address);
        assert!(!nft_lockup.is_borrowed, error::permission_denied(ENFT_BORROWED));
        let StrategyNFTLockup { is_borrowed: _, transfer_ref: _, mutator_ref: _, burn_ref } =
            move_from<StrategyNFTLockup>(token_address);

        // Retrieve the burn ref from storage
        token::burn(burn_ref);
    }

    public entry fun borrow_nft(
        account: &signer, token: Object<Token>
    ) acquires Strategy, StrategyNFT, StrategyNFTLockup {
        let nft_addr = object::object_address(&token);
        let collection_object = collection_object(token);
        let strategy_addr = collection::creator(collection_object);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);
        assert!(option::is_none(&nft.borrow), ENFT_BORROWED);
        assert!(
            object::is_owner(token, signer::address_of(account)),
            error::permission_denied(ENOT_TOKEN_OWNER)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);

        object::disable_ungated_transfer(&lockup.transfer_ref);
        nft.borrow = option::some(strategy.livtorgex_owner);
        lockup.is_borrowed = true;
        strategy_events::emit_borrow_strategy_nft(nft_addr, strategy.livtorgex_owner);
    }

    public entry fun release_nft(
        account: &signer, token: Object<Token>
    ) acquires StrategyNFT, StrategyNFTLockup {
        let nft_addr = object::object_address(&token);
        let collection_object = collection_object(token);
        let strategy_addr = collection::creator(collection_object);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);
        assert!(option::is_some(&nft.borrow), ENFT_NOT_BORROW);
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global_mut<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, ENFT_NOT_BORROW);

        object::enable_ungated_transfer(&lockup.transfer_ref);
        nft.borrow = option::none();
        lockup.is_borrowed = false;

        strategy_events::emit_release_strategy_nft(strategy_addr, nft_addr);
    }

    // Spend the energy. Should be called from restricted accounts
    public entry fun use_nft_energy(
        account: &signer, token: Object<Token>, profit: u64
    ) acquires StrategyNFT, StrategyNFTLockup {
        let nft_addr = object::object_address(&token);
        let collection_object = collection_object(token);
        let strategy_addr = collection::creator(collection_object);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);

        assert!(option::is_some(&nft.borrow), ENFT_NOT_BORROW);
        assert!(
            signer::address_of(account) == *option::borrow<address>(&nft.borrow),
            error::permission_denied(EACCESS_DENIEND)
        );

        let lockup = borrow_global<StrategyNFTLockup>(nft_addr);
        assert!(lockup.is_borrowed, error::permission_denied(ENFT_NOT_BORROW));

        let energy_usage: u64 = 0;

        if (nft.k_profit != 0 && profit != 0) {
            energy_usage = energy_usage + (nft.k_profit * profit) / NFT_PRECISION;
        };

        if (energy_usage >= nft.energy) {
            nft.energy = 0;
        } else {
            nft.energy = nft.energy - energy_usage;
        };

        if (energy_usage >= nft.energy_refill_capacity) {
            nft.energy_refill_capacity = 0;
        } else {
            nft.energy_refill_capacity = nft.energy_refill_capacity - energy_usage;
        };

        nft.profit = nft.profit + profit;

        strategy_events::emit_use_strategy_nft(
            strategy_addr,
            nft_addr,
            energy_usage,
            *option::borrow<address>(&nft.borrow)
        );
    }

    /// Change energy refill capacity for more or less usage
    public entry fun change_energy_refill_capacity(
        account: &signer,
        token: Object<Token>,
        capacity: u64,
        action: u64
    ) acquires Strategy, StrategyNFT {
        let nft_addr = object::object_address(&token);
        let collection_object = collection_object(token);
        let strategy_addr = collection::creator(collection_object);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let account_addr = signer::address_of(account);
        let strategy = borrow_global<Strategy>(strategy_addr);
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);
        assert!(
            account_addr == strategy.owner || account_addr == strategy.livtorgex_owner,
            error::permission_denied(EACCESS_DENIEND)
        );

        if (action == NFT_ENERGY_REFILL_CAPACITY_REQUEST_ADD) {
            nft.energy_refill_capacity = nft.energy_refill_capacity + capacity;
        };
        if (action == NFT_ENERGY_REFILL_CAPACITY_REQUEST_SUBTRACT) {
            if (nft.energy_refill_capacity > capacity) {
                nft.energy_refill_capacity = nft.energy_refill_capacity - capacity;
            } else {
                nft.energy_refill_capacity = 0;
            }
        };

        strategy_events::emit_change_energy_refill_capacity(
            strategy_addr,
            token::name(token),
            capacity,
            action,
            nft.energy
        );
    }

    // Refill the energy
    // anyone can refill the energy
    public entry fun refill_energy<T: key>(
        account: &signer,
        token: Object<Token>,
        asset: Object<T>,
        energy: u64
    ) acquires Strategy, StrategyNFT {
        let nft_addr = object::object_address(&token);
        let collection_object = collection_object(token);
        let strategy_addr = collection::creator(collection_object);
        assert!(
            exists<Strategy>(strategy_addr),
            error::not_found(ESTRATEGY_NOT_EXIST)
        );
        let strategy = borrow_global<Strategy>(strategy_addr);

        assert!(
            vector::contains(&strategy.payment_coins, &object::object_address(&asset)),
            error::permission_denied(ENFT_NOT_STABLECOIN)
        );
        let nft = borrow_global_mut<StrategyNFT>(nft_addr);

        // Ensure that capacity enough to refill
        assert!(
            nft.energy_refill_capacity != 0,
            error::resource_exhausted(ENFT_NOT_ENERGY_REFILL_CAPACITY)
        );

        let refill_energy =
            if (energy + nft.energy > NFT_MAX_ENERGY) {
                NFT_MAX_ENERGY - nft.energy
            } else { energy };

        assert!(refill_energy != 0, ENFT_ENERGY_FULL);

        let decimals = fungible_asset::decimals(asset);
        let stablecoin_denominator = math64::pow(10, decimals as u64);
        let expo_magnitude = NFT_REFILL_DENOMINATOR / stablecoin_denominator;

        // Just to 1to1 rate. Specify any tokens in the is_allowed_coin_type that can use for stable coin
        let full_amount = NFT_REFILL_DENOMINATOR / nft.k_refill
            * NFT_REFILL_DENOMINATOR;
        let refill_amount = bounded_percentage(full_amount, energy, NFT_PRECISION * 100);
        let initial_amount: u64 = refill_amount / expo_magnitude;

        let livtorgex_amount =
            bounded_percentage(
                initial_amount, strategy.livtorgex_fee, NFT_REFILL_DENOMINATOR
            );
        primary_fungible_store::transfer(
            account,
            asset,
            strategy.livtorgex_owner,
            livtorgex_amount
        );

        let owner_amount = initial_amount - livtorgex_amount;

        let royalty = token::royalty(object::address_to_object<Token>(nft_addr));
        if (option::is_some(&royalty)) {
            let royalty = option::destroy_some(royalty);
            let payee_address = royalty::payee_address(&royalty);
            let numerator = royalty::numerator(&royalty);
            let denominator = royalty::denominator(&royalty);

            let royalty_amount = bounded_percentage(
                initial_amount, numerator, denominator
            );
            primary_fungible_store::transfer(
                account, asset, payee_address, royalty_amount
            );

            owner_amount = owner_amount - royalty_amount;
        };

        primary_fungible_store::transfer(account, asset, strategy.owner, owner_amount);

        nft.energy = nft.energy + refill_energy;

        strategy_events::emit_refill_energy(
            strategy_addr,
            token::name(token),
            object::object_address(&asset),
            refill_energy,
            nft.energy
        );
    }

    inline fun get_nft_address(
        creator: &address, collection: &String, name: &String
    ): address {
        token::create_token_address(creator, collection, name)
    }

    public inline fun bounded_percentage(
        amount: u64, numerator: u64, denominator: u64
    ): u64 {
        if (denominator == 0) { 0 }
        else {
            math64::min(
                amount,
                math64::mul_div(amount, numerator, denominator)
            )
        }
    }

    #[test_only]
    public fun init_for_test(owner: &signer) {
        init_module(owner);
    }

    #[test_only]
    fun create_test_strategy(account: &signer): address acquires Management {
        let name = string::utf8(b"Subscription");
        let description = string::utf8(b"Test NFT for subscription");
        let uri = string::utf8(b"URI");

        create_strategy_and_get_strategy_address(
            account,
            name,
            description,
            uri,
            10 * NFT_REFILL_DENOMINATOR,
            signer::address_of(account)
        )
    }

    #[test_only]
    fun create_test_nfts(account: &signer, strategy_addr: address): (String, u64) acquires Strategy {
        let company_code = string::utf8(b"LivTorgEx");
        let nft_name = string::utf8(b"Subscription");
        let uri = string::utf8(b"https:://livtorgex.com");
        let description = string::utf8(b"Test NFT for subscription");
        let energy: u64 = 50 * NFT_PRECISION; // 50.00000
        let k_refill: u64 = 1 * NFT_REFILL_DENOMINATOR; // 1.00000 (100% refill rate)
        let k_profit: u64 = 2_5 * NFT_PRECISION / 100; // 2.50000

        mint_nfts(
            account,
            strategy_addr,
            company_code,
            0,
            NFT_ROLE_INDIVIDUAL,
            description,
            nft_name,
            1,
            uri,
            energy,
            NFT_PRECISION * 1000,
            k_refill,
            k_profit,
            option::none(),
            option::none()
        );

        (nft_name, energy)
    }

    #[test_only]
    fun assign_fa_to_strategy(
        account: &signer, strategy_addr: address
    ): Object<fungible_asset::Metadata> acquires Strategy {
        let (mint_ref, _, _, _, metadata) =
            fungible_asset::create_fungible_asset(account);
        // let (creator_ref, metadata) = fungible_asset::create_test_token(account);
        // let (mint_ref, _, _, _) = fungible_asset::init_test_metadata(&creator_ref);
        let account_store = fungible_asset::create_test_store(account, metadata);
        let fa = fungible_asset::mint(&mint_ref, 10);
        fungible_asset::deposit(account_store, fa);

        strategy_change_payment_coins(
            account, strategy_addr, vector[object::object_address(&metadata)]
        );

        metadata
    }

    #[test(owner = @0xcafe, account = @0xbab)]
    fun test_strategy_name(owner: &signer, account: &signer) acquires Management {
        init_for_test(owner);
        let name = string::utf8(b"Subscription");
        let strategy_addr = create_test_strategy(account);

        assert!(get_strategy_address(name) == strategy_addr, 0);
    }

    #[test(owner = @0xcafe, account = @0xbab)]
    fun test_nft_creating(owner: &signer, account: &signer) acquires Management, Strategy, StrategyNFT {
        init_for_test(owner);

        let name = string::utf8(b"Subscription");
        let nft_name = string::utf8(b"Subscription #1");

        let energy: u64 = 50 * NFT_PRECISION; // 50.00000
        let k_refill: u64 = 1 * NFT_REFILL_DENOMINATOR; // 1.00000 (100% refill rate)
        let k_profit: u64 = 2_5 * NFT_PRECISION / 100; // 2.50000

        let strategy_addr = create_test_strategy(account);
        create_test_nfts(account, strategy_addr);

        let nft_address = get_nft_address(&strategy_addr, &name, &nft_name);
        let nft = borrow_global<StrategyNFT>(nft_address);

        assert!(nft.energy == energy, 100);
        assert!(nft.k_refill == k_refill, 101);
        assert!(nft.k_profit == k_profit, 102);
    }

    #[test(owner = @0xcafe, account = @0xbab)]
    fun test_nft_energy_refill(
        owner: &signer, account: &signer
    ) acquires Management, Strategy, StrategyNFT {
        init_for_test(owner);

        let name = string::utf8(b"Subscription");
        let nft_name = string::utf8(b"Subscription #1");

        let initial_energy = 50 * NFT_PRECISION; // 50.00000
        let fill_energy: u64 = 1 * NFT_PRECISION; // 1.00000

        let strategy_addr = create_test_strategy(account);
        create_test_nfts(account, strategy_addr);
        let metadata = assign_fa_to_strategy(account, strategy_addr);
        let nft_address = get_nft_address(&strategy_addr, &name, &nft_name);
        let nft = object::address_to_object<Token>(nft_address);

        refill_energy(account, nft, metadata, fill_energy);

        let nft = borrow_global<StrategyNFT>(nft_address);

        assert!(nft.energy == initial_energy + fill_energy, 100);

    }
}
