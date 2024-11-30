module livtorgex::strategy_events {
    use std::signer;
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
    struct MintStrategyNFT has drop, store {
        strategy_addr: address,
        company_name: String,
        name: String,
        description: String,
        energy: u64,
        k_refill: u64,
        k_profit: u64,
        k_volume: u64,
        k_time: u64
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
    struct StartStrategyNFT has drop, store {
        strategy_addr: address,
        nft: address
    }

    #[event]
    struct StopStrategyNFT has drop, store {
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
        strategy_addr: &signer,
        name: String,
        admin: address
    ) {
        event::emit(
            CreateStrategy { strategy_addr: signer::address_of(strategy_addr), name, admin }
        );
    }

    public(friend) fun emit_mint_strategy_nft(
        strategy_addr: address,
        company_name: String,
        name: String,
        description: String,
        energy: u64,
        k_refill: u64,
        k_profit: u64,
        k_volume: u64,
        k_time: u64
    ) {
        event::emit(
            MintStrategyNFT {
                strategy_addr,
                company_name,
                name,
                description,
                energy,
                k_refill,
                k_profit,
                k_volume,
                k_time
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

    public(friend) fun emit_start_strategy_nft(
        strategy_addr: address, nft: address
    ) {
        event::emit(StartStrategyNFT { strategy_addr, nft });
    }

    public(friend) fun emit_stop_strategy_nft(
        strategy_addr: address, nft: address
    ) {
        event::emit(StopStrategyNFT { strategy_addr, nft });
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
