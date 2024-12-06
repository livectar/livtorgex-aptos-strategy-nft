module livtorgex::strategy_events {
    use std::string::String;

    use aptos_framework::event;

    friend livtorgex::strategy;

    #[event]
    struct CreateStrategy has drop, store {
        strategy_addr: address,
        name: String,
        admin: address
    }

    #[event]
    struct StrategyOwnerOffer has drop, store {
        owner: address,
        new_owner: address,
        strategy: address
    }

    #[event]
    struct StrategyOwnerOfferCancel has drop, store {
        owner: address,
        strategy: address
    }

    #[event]
    struct StrategyOwnerClaim has drop, store {
        old_owner: address,
        new_owner: address,
        strategy: address
    }

    #[event]
    struct StrategyChangePaymentCoinsAddress has drop, store {
        owner: address,
        payment_coins: vector<address>,
        strategy: address
    }

    #[event]
    struct StrategyChangeLivtorgexAddress has drop, store {
        old_owner: address,
        new_owner: address,
        strategy: address
    }

    #[event]
    struct StrategyRequestLivtorgex has drop, store {
        owner: address,
        fee: u64,
        strategy: address
    }

    #[event]
    struct StrategyResolveLivtorgex has drop, store {
        owner: address,
        status: u64,
        strategy: address
    }

    #[event]
    struct MintStrategyNFT has drop, store {
        strategy_addr: address,
        company_name: String,
        name: String,
        description: String,
        energy: u64,
        k_refill: u64,
        k_profit: u64
    }

    #[event]
    struct BorrowStrategyNFT has drop, store {
        nft: address,
        borrow: address
    }

    #[event]
    struct ReleaseStrategyNFT has drop, store {
        strategy_addr: address,
        nft: address
    }

    #[event]
    struct UseStrategyNFT has drop, store {
        strategy_addr: address,
        nft: address,
        energy: u64,
        borrow: address
    }

    public(friend) fun emit_create_strategy(
        strategy_addr: address, name: String, admin: address
    ) {
        event::emit(CreateStrategy { strategy_addr, name, admin });
    }

    public(friend) fun emit_strategy_owner_offer_event(
        owner: address, new_owner: address, strategy: address
    ) {
        event::emit(StrategyOwnerOffer { owner, new_owner, strategy });
    }

    public(friend) fun emit_strategy_owner_offer_cancel_event(
        owner: address, strategy: address
    ) {
        event::emit(StrategyOwnerOfferCancel { owner, strategy });
    }

    public(friend) fun emit_strategy_owner_claim_event(
        old_owner: address, new_owner: address, strategy: address
    ) {
        event::emit(StrategyOwnerClaim { old_owner, new_owner, strategy });
    }

    public(friend) fun emit_strategy_change_livtorgex_address_event(
        old_owner: address, new_owner: address, strategy: address
    ) {
        event::emit(StrategyChangeLivtorgexAddress { old_owner, new_owner, strategy });
    }

    public(friend) fun emit_strategy_change_payment_coins_event(
        owner: address, payment_coins: vector<address>, strategy: address
    ) {
        event::emit(StrategyChangePaymentCoinsAddress { owner, payment_coins, strategy });
    }

    public(friend) fun emit_strategy_request_livtorgex_event(
        owner: address, fee: u64, strategy: address
    ) {
        event::emit(StrategyRequestLivtorgex { owner, fee, strategy });
    }

    public(friend) fun emit_strategy_resolve_livtorgex_event(
        owner: address, status: u64, strategy: address
    ) {
        event::emit(StrategyResolveLivtorgex { owner, status, strategy });
    }

    public(friend) fun emit_mint_strategy_nft(
        strategy_addr: address,
        company_name: String,
        name: String,
        description: String,
        energy: u64,
        k_refill: u64,
        k_profit: u64
    ) {
        event::emit(
            MintStrategyNFT {
                strategy_addr,
                company_name,
                name,
                description,
                energy,
                k_refill,
                k_profit
            }
        );
    }

    public(friend) fun emit_borrow_strategy_nft(
        nft: address, borrow: address
    ) {
        event::emit(BorrowStrategyNFT { nft, borrow });
    }

    public(friend) fun emit_release_strategy_nft(
        strategy_addr: address, nft: address
    ) {
        event::emit(ReleaseStrategyNFT { strategy_addr, nft });
    }

    public(friend) fun emit_use_strategy_nft(
        strategy_addr: address,
        nft: address,
        energy: u64,
        borrow: address
    ) {
        event::emit(
            UseStrategyNFT { strategy_addr, nft, energy, borrow }
        );
    }
}
