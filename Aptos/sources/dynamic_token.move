module bonding_curve_token::dynamic_token {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::account;
    use aptos_framework::coin::{Self, Coin, BurnCapability, FreezeCapability, MintCapability};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::aptos_coin::AptosCoin;

    /// Error codes
    const ERROR_NOT_ADMIN: u64 = 1;
    const ERROR_ZERO_AMOUNT: u64 = 2;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 3;
    const ERROR_MAX_SUPPLY_REACHED: u64 = 4;
    const ERROR_INVALID_PARAMETER: u64 = 5;

    /// Token metadata
    struct DynamicToken {}

    /// Resource stored under the admin account
    struct TokenAdmin has key {
        // Capabilities for minting, burning, and freezing
        mint_cap: MintCapability<DynamicToken>,
        burn_cap: BurnCapability<DynamicToken>,
        freeze_cap: FreezeCapability<DynamicToken>,
        
        // Token configuration
        base_price: u64,             // Base price in APT (scaled by 10^8)
        price_increase_factor: u64,  // Factor for price increase (scaled by 10^8)
        max_supply: u64,             // Maximum token supply
        total_supply: u64,           // Current total supply
        sell_discount: u64,          // Discount when selling (e.g., 90% = 9000)
        
        // Treasury
        collected_apt: u64,          // Total APT collected from purchases
        
        // Events
        purchase_events: EventHandle<PurchaseEvent>,
        sale_events: EventHandle<SaleEvent>,
        config_update_events: EventHandle<ConfigUpdateEvent>,
    }

    /// Event emitted when tokens are purchased
    struct PurchaseEvent has drop, store {
        buyer: address,
        apt_amount: u64,
        tokens_minted: u64,
        price_per_token: u64,
    }

    /// Event emitted when tokens are sold back
    struct SaleEvent has drop, store {
        seller: address,
        tokens_sold: u64,
        apt_returned: u64,
        price_per_token: u64,
    }

    /// Event emitted when config is updated
    struct ConfigUpdateEvent has drop, store {
        base_price: u64,
        price_increase_factor: u64,
        sell_discount: u64,
    }

    /// Initialize the token and create admin resource
    public entry fun initialize(
        admin: &signer,
        name: String,
        symbol: String,
        decimals: u8,
        base_price: u64,
        price_increase_factor: u64,
        max_supply: u64,
        sell_discount: u64,
    ) {
        let admin_addr = signer::address_of(admin);
        
        // Validate parameters
        assert!(base_price > 0, error::invalid_argument(ERROR_INVALID_PARAMETER));
        assert!(price_increase_factor > 0, error::invalid_argument(ERROR_INVALID_PARAMETER));
        assert!(max_supply > 0, error::invalid_argument(ERROR_INVALID_PARAMETER));
        assert!(sell_discount > 0 && sell_discount <= 10000, error::invalid_argument(ERROR_INVALID_PARAMETER));
        
        // Register the token
        let (mint_cap, burn_cap, freeze_cap) = coin::initialize<DynamicToken>(
            admin,
            name,
            symbol,
            decimals,
            true, // monitor_supply
        );
        
        // Create admin resource
        move_to(admin, TokenAdmin {
            mint_cap,
            burn_cap,
            freeze_cap,
            base_price,
            price_increase_factor,
            max_supply,
            total_supply: 0,
            sell_discount,
            collected_apt: 0,
            purchase_events: account::new_event_handle<PurchaseEvent>(admin),
            sale_events: account::new_event_handle<SaleEvent>(admin),
            config_update_events: account::new_event_handle<ConfigUpdateEvent>(admin),
        });
    }

    /// Calculate the current token price based on supply
    public fun calculate_price(admin_addr: address): u64 acquires TokenAdmin {
        let admin = borrow_global<TokenAdmin>(admin_addr);
        let supply_ratio = (admin.total_supply as u128) * 100000000 / (admin.max_supply as u128);
        let price_factor = 100000000 + (supply_ratio * (admin.price_increase_factor as u128) / 100000000);
        let current_price = (admin.base_price as u128) * price_factor / 100000000;
        
        (current_price as u64)
    }

    /// Buy tokens with APT
    public entry fun buy_tokens(
        buyer: &signer,
        admin_addr: address,
        apt_amount: u64
    ) acquires TokenAdmin {
        // Validate input
        assert!(apt_amount > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));
        
        let buyer_addr = signer::address_of(buyer);
        let admin = borrow_global_mut<TokenAdmin>(admin_addr);
        
        // Calculate current price
        let current_price = calculate_price(admin_addr);
        
        // Calculate tokens to mint (accounting for decimals)
        let tokens_to_mint = (apt_amount as u128) * 100000000 / (current_price as u128);
        let tokens_to_mint = (tokens_to_mint as u64);
        
        // Check max supply
        assert!(admin.total_supply + tokens_to_mint <= admin.max_supply, 
               error::resource_exhausted(ERROR_MAX_SUPPLY_REACHED));
        
        // Transfer APT from buyer to module
        let apt_coins = coin::withdraw<AptosCoin>(buyer, apt_amount);
        coin::deposit(admin_addr, apt_coins);
        
        // Mint tokens to buyer
        let tokens = coin::mint<DynamicToken>(tokens_to_mint, &admin.mint_cap);
        coin::deposit(buyer_addr, tokens);
        
        // Update state
        admin.total_supply = admin.total_supply + tokens_to_mint;
        admin.collected_apt = admin.collected_apt + apt_amount;
        
        // Emit event
        event::emit_event(&mut admin.purchase_events, PurchaseEvent {
            buyer: buyer_addr,
            apt_amount,
            tokens_minted: tokens_to_mint,
            price_per_token: current_price,
        });
    }

    /// Sell tokens back to the contract
    public entry fun sell_tokens(
        seller: &signer,
        admin_addr: address,
        token_amount: u64
    ) acquires TokenAdmin {
        // Validate input
        assert!(token_amount > 0, error::invalid_argument(ERROR_ZERO_AMOUNT));
        
        let seller_addr = signer::address_of(seller);
        let admin = borrow_global_mut<TokenAdmin>(admin_addr);
        
        // Calculate current price with discount
        let current_price = calculate_price(admin_addr);
        let discounted_price = (current_price as u128) * (admin.sell_discount as u128) / 10000;
        let discounted_price = (discounted_price as u64);
        
        // Calculate APT to return
        let apt_to_return = (token_amount as u128) * (discounted_price as u128) / 100000000;
        let apt_to_return = (apt_to_return as u64);
        
        // Check if contract has enough APT
        assert!(apt_to_return <= admin.collected_apt, error::resource_exhausted(ERROR_INSUFFICIENT_BALANCE));
        
        // Transfer tokens from seller to be burned
        let tokens = coin::withdraw<DynamicToken>(seller, token_amount);
        coin::burn(tokens, &admin.burn_cap);
        
        // Transfer APT from module to seller
        let apt_coins = coin::withdraw<AptosCoin>(&account::create_signer_with_capability(
            &account::create_test_signer_cap(admin_addr)
        ), apt_to_return);
        coin::deposit(seller_addr, apt_coins);
        
        // Update state
        admin.total_supply = admin.total_supply - token_amount;
        admin.collected_apt = admin.collected_apt - apt_to_return;
        
        // Emit event
        event::emit_event(&mut admin.sale_events, SaleEvent {
            seller: seller_addr,
            tokens_sold: token_amount,
            apt_returned: apt_to_return,
            price_per_token: discounted_price,
        });
    }

    /// Update contract configuration (admin only)
    public entry fun update_config(
        admin: &signer,
        base_price: u64,
        price_increase_factor: u64,
        sell_discount: u64
    ) acquires TokenAdmin {
        let admin_addr = signer::address_of(admin);
        
        // Verify admin
        assert!(exists<TokenAdmin>(admin_addr), error::permission_denied(ERROR_NOT_ADMIN));
        
        // Validate parameters
        assert!(base_price > 0, error::invalid_argument(ERROR_INVALID_PARAMETER));
        assert!(price_increase_factor > 0, error::invalid_argument(ERROR_INVALID_PARAMETER));
        assert!(sell_discount > 0 && sell_discount <= 10000, error::invalid_argument(ERROR_INVALID_PARAMETER));
        
        let admin_resource = borrow_global_mut<TokenAdmin>(admin_addr);
        
        // Update configuration
        admin_resource.base_price = base_price;
        admin_resource.price_increase_factor = price_increase_factor;
        admin_resource.sell_discount = sell_discount;
        
        // Emit event
        event::emit_event(&mut admin_resource.config_update_events, ConfigUpdateEvent {
            base_price,
            price_increase_factor,
            sell_discount,
        });
    }

    /// Get token information
    public fun get_token_info(admin_addr: address): (u64, u64, u64, u64, u64) acquires TokenAdmin {
        let admin = borrow_global<TokenAdmin>(admin_addr);
        
        (
            admin.base_price,
            admin.price_increase_factor,
            admin.total_supply,
            admin.max_supply,
            admin.collected_apt
        )
    }

    /// Get current token price
    public entry fun get_current_price(admin_addr: address): u64 acquires TokenAdmin {
        calculate_price(admin_addr)
    }

    /// Withdraw collected APT (admin only)
    public entry fun withdraw_collected_apt(
        admin: &signer,
        amount: u64
    ) acquires TokenAdmin {
        let admin_addr = signer::address_of(admin);
        
        // Verify admin
        assert!(exists<TokenAdmin>(admin_addr), error::permission_denied(ERROR_NOT_ADMIN));
        
        let admin_resource = borrow_global_mut<TokenAdmin>(admin_addr);
        
        // Check if enough APT is available
        assert!(amount <= admin_resource.collected_apt, error::resource_exhausted(ERROR_INSUFFICIENT_BALANCE));
        
        // Withdraw APT
        let apt_coins = coin::withdraw<AptosCoin>(&account::create_signer_with_capability(
            &account::create_test_signer_cap(admin_addr)
        ), amount);
        coin::deposit(admin_addr, apt_coins);
        
        // Update state
        admin_resource.collected_apt = admin_resource.collected_apt - amount;
    }
}