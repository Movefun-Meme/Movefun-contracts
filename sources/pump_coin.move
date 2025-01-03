module pump::pump {
    use std::signer::address_of;
    use std::type_info;
    use std::signer;
    use std::string;
    use std::string::String;
    use std::vector;
    use aptos_std::math64;
    use aptos_std::type_info::type_name;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use aptos_framework::event;
    use aptos_framework::timestamp;

    use razor_amm::router;

    //errors
    const ERROR_INVALID_LENGTH: u64 = 1;
    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_INITIALIZED: u64 = 3;
    const ERROR_NOT_ALLOW_PRE_MINT: u64 = 4;
    const ERROR_ALREADY_PUMP: u64 = 5;
    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 8;
    const ERROR_PUMP_AMOUNT_TO_LOW: u64 = 9;
    const ERROR_TOKEN_DECIMAL: u64 = 10;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_PUMP_NOT_COMPLETED: u64 = 14;
    const ERROR_EXCEED_TRANSFER_THRESHOLD: u64 = 15;
    const ERROR_BELOW_TRANSFER_THRESHOLD: u64 = 16;
    const ERROR_AMOUNT_TOO_LOW: u64 = 17;
    const ERROR_NO_LAST_BUYER: u64 = 18;
    const ERROR_NOT_LAST_BUYER: u64 = 19;
    const ERROR_WAIT_TIME_NOT_REACHED: u64 = 20;
    const ERROR_NO_SELL_IN_HIGH_FEE_PERIOD: u64 = 21;
    const ERROR_NOT_NORMAL_DEX: u64 = 22;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 23;
    const ERROR_WAIT_DURATION_PASSED: u64 = 24;
    // Decimal places for (8)
    const DECIMALS: u64 = 100_000_000;

    /* 
    Configuration for the Pump module
    */
    struct PumpConfig has key, store {
        platform_fee: u64,                
        resource_cap: SignerCapability,   
        platform_fee_address: address,    
        initial_virtual_token_reserves: u64, 
        initial_virtual_move_reserves: u64, 
        token_decimals: u8,              
        dex_transfer_threshold: u64,     
        wait_duration: u64,      // 8 hours = 28800 seconds
        min_move_amount: u64,    // Minimum purchase amount = 100_000_000 (1 MOVE)
        high_fee: u64,          // High fee rate period fee = 1000 (10%)
    }

    /* 
    Pool struct that holds both real and virtual reserves
    */
    struct Pool<phantom CoinType> has key, store {
        real_token_reserves: Coin<CoinType>,
        real_move_reserves: Coin<AptosCoin>,
        virtual_token_reserves: u64,
        virtual_move_reserves: u64,
        token_freeze_cap: coin::FreezeCapability<CoinType>,
        token_burn_cap: coin::BurnCapability<CoinType>,
        is_completed: bool,
        is_normal_dex: bool,
        dev: address
    }

    // struct to track the last buyer
    struct LastBuyer<phantom CoinType> has key, drop {
        buyer: address,
        timestamp: u64,
        token_amount: u64
    }

    // Event handle struct for all pump-related events
    struct Handle has key {
        created_events: event::EventHandle<PumpEvent>,
        trade_events: event::EventHandle<TradeEvent>,
        transfer_events: event::EventHandle<TransferEvent>,
        unfreeze_events: event::EventHandle<UnfreezeEvent>
    }

    // Event emitted when a new pump is created
    #[event]
    struct PumpEvent has drop, store {
        pool: String,
        dev: address,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        platform_fee: u64,
        initial_virtual_token_reserves: u64,
        initial_virtual_move_reserves: u64,
        token_decimals: u8
    }

    //Event emitted for each trade
    #[event]
    struct TradeEvent has drop, store {
        move_amount: u64,
        is_buy: bool,
        token_address: String,
        token_amount: u64,
        user: address,
        virtual_move_reserves: u64,
        virtual_token_reserves: u64,
        timestamp: u64
    }

    //Event emitted when tokens are transferred
    #[event]
    struct TransferEvent has drop, store {
        move_amount: u64,
        token_address: String,
        token_amount: u64,
        user: address,
        virtual_move_reserves: u64,
        virtual_token_reserves: u64,
        burned_amount: u64
    }

    //Event emitted when a token account is unfrozen
    #[event]
    struct UnfreezeEvent has drop, store {
        token_address: String,
        user: address
    }

    //View function to calculate the amount of token required for a buy operation
    //@param buy_token_amount - Amount of token to buy
    #[view]
    public fun buy_token_amount<CoinType>(buy_token_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);

        let liquidity_cost = calculate_add_liquidity_cost(
            (pool.virtual_move_reserves as u256),
            (pool.virtual_token_reserves as u256),
            (buy_token_amount as u256)
        );

        (liquidity_cost as u64)
    }

    //View function to calculate the amount of token required for a buy operation
    //@param buy_move_amount - Amount of MOVE to buy
    #[view]
    public fun buy_move_amount<CoinType>(buy_move_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);

        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);

        (
            calculate_buy_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_move_reserves as u256),
                (buy_move_amount as u256)
            ) as u64
        )
    }

    //View function to calculate the amount of MOVE received when selling
    //@param sell_token_amount - Amount of token to sell
    #[view]
    public fun sell_token<CoinType>(sell_token_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resorce_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resorce_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resorce_addr);
        let liquidity_remove =
            calculate_sell_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_move_reserves as u256),
                (sell_token_amount as u256)
            );

        (liquidity_remove as u64)
    }

    //Gets the current price of MOVE/MEME token
    #[view]
    public fun get_current_price<CoinType>(): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global<Pool<CoinType>>(resource_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        
        let move_reserves = (pool.virtual_move_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);
        
        ((move_reserves * 100_000_000) / token_reserves) as u64
    }

    //Gets the current state of the pool
    //(virtual MEME token reserves, virtual MOVE reserves, remaining MEME tokens, completion status)
    #[view]
    public fun get_pool_state<CoinType>(): (u64, u64, bool) acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global<Pool<CoinType>>(resource_addr);
        (
            pool.virtual_token_reserves,
            pool.virtual_move_reserves,
            pool.is_completed
        )
    }

    //Calculates the amount of MOVE needed for a specific MEME token purchase with fees
    //@param buy_meme_amount - Amount of MEME tokens to buy
    #[view]
    public fun buy_price_with_fee<CoinType>(buy_meme_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let move_amount = buy_move_amount<CoinType>(buy_meme_amount);
        let platform_fee = math64::mul_div(move_amount, fee, 10000);
        move_amount + platform_fee
    }

    //Calculates the amount of MOVE to receive when selling MEME tokens after fees
    //@param sell_meme_amount - Amount of MEME tokens to sell
    #[view]
    public fun sell_price_with_fee<CoinType>(sell_meme_amount: u64): u64 acquires PumpConfig, Pool {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let move_amount = sell_token<CoinType>(sell_meme_amount);
        let platform_fee = math64::mul_div(move_amount, fee, 10000);
        move_amount - platform_fee
    }
    
    /*
    * Calculates the price impact for a given trade
    * @param amount - Trade amount
    * @param is_buy - Whether this is a buy operation
    * @return Price impact in basis points (1/10000) (1 = 0.01%)
    */
    #[view]
    public fun get_price_impact<CoinType>(amount: u64, is_buy: bool): u64 acquires PumpConfig, Pool {
        if (amount == 0) {
            return 0
        };

        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global<Pool<CoinType>>(resource_addr);
        let move_reserves = (pool.virtual_move_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);
        let amount_256 = (amount as u256);

        if (token_reserves == 0 || move_reserves == 0) {
            return 0
        };
        
        let initial_price = (move_reserves * 100_000_000) / token_reserves;
        
        let final_price = if (is_buy) {
            let move_in = calculate_add_liquidity_cost(move_reserves, token_reserves, amount_256);
            let new_move = move_reserves + move_in;
            let new_token = token_reserves - amount_256;
            if (new_token == 0) {
                return 10000 // 100% impact
            };
            (new_move * 100_000_000) / new_token
        } else {
            let move_out = calculate_sell_token(token_reserves, move_reserves, amount_256);
            let new_move = move_reserves - move_out;
            let new_token = token_reserves + amount_256;
            if (new_move == 0) {
                return 10000 // 100% impact
            };
            (new_move * 100_000_000) / new_token
        };

        if (initial_price == 0) {
            return 10000 // 100% impact
        };

        let price_diff = if (final_price > initial_price) {
            (final_price - initial_price) * 10000
        } else {
            (initial_price - final_price) * 10000
        };
        
        ((price_diff / initial_price) as u64)
    }
    
    // Get last buyer information
    #[view]
    public fun get_last_buyer<CoinType>(): (address, u64, u64) acquires PumpConfig, LastBuyer {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        if (!exists<LastBuyer<CoinType>>(resource_addr)) {
            return (@0x0, 0, 0)
        };
        
        let last_buyer = borrow_global<LastBuyer<CoinType>>(resource_addr);
        (last_buyer.buyer, last_buyer.timestamp + config.wait_duration, last_buyer.token_amount)
    }

    // Get current pump stage
    #[view]
    public fun get_pump_stage<CoinType>(): u8 acquires PumpConfig, Pool, LastBuyer {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global<Pool<CoinType>>(resource_addr);
        
        let current_move_balance = coin::value<AptosCoin>(&pool.real_move_reserves);
        
        // Stage 1: Before reaching threshold
        if (current_move_balance < config.dex_transfer_threshold) {
            return 1
        };
        
        // Stage 2: After threshold but before wait duration
        if (exists<LastBuyer<CoinType>>(resource_addr)) {
            let last_buyer = borrow_global<LastBuyer<CoinType>>(resource_addr);
            let current_time = timestamp::now_seconds();
            
            if (current_time < last_buyer.timestamp + config.wait_duration) {
                return 2
            };
            
            // Stage 3: After wait duration
            return 3
        };
        
        // Stage 2: After threshold but no last buyer yet
        1
    }

    // ========================================= Helper Function ========================================
    /*
    Calculates the amount of MOVE when buying
    @param virtual_move_reserves - Current virtual MOVE reserves (x)
    @param virtual_token_reserves - Current virtual token reserves (y)
    @param token_amount - Amount of token to add (delta y)
    @return MOVE amount required (delta x)
    Formula: delta x = ((x * y) / (y - delta y)) - x
    */
    fun calculate_add_liquidity_cost(
        move_reserves: u256, token_reserves: u256, token_amount: u256
    ): u256 {
        assert!(move_reserves > 0 && token_reserves > 0 && token_amount > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        let reserve_diff = token_reserves - token_amount;
        assert!(reserve_diff > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        ((move_reserves * token_reserves) / reserve_diff) + 1 - move_reserves
    }

    /*
    Calculates the amount of MOVE received when selling
    @param token_reserves - Current virtual token reserves (y)
    @param move_reserves - Current virtual MOVE reserves (x)
    @param token_value - Value of the token (delta y)
    @return MOVE amount received (delta x)
    Formula: delta x = x - ((x * y) / (y + delta y))
    */
    fun calculate_sell_token(
        token_reserves: u256, move_reserves: u256, token_value: u256
    ): u256 {
        assert!(token_reserves > 0 && move_reserves > 0 && token_value > 0, ERROR_INSUFFICIENT_LIQUIDITY);
 
        move_reserves - ((token_reserves * move_reserves) / (token_value + token_reserves)) - 1
    }

    /*
    Calculates the amount of token received when buying
    @param token_reserves - Current virtual token reserves (y)
    @param move_reserves - Current virtual MOVE reserves (x)
    @param move_value - Value of MOVE (delta x)
    @return Token amount received (delta y)
    Formula: delta y = y - ((x * y) / (x + delta x))
    */
    fun calculate_buy_token(
        token_reserves: u256, move_reserves: u256, move_value: u256
    ): u256 {
        assert!(token_reserves > 0 && move_reserves > 0 && move_value > 0, ERROR_INSUFFICIENT_LIQUIDITY);    
        token_reserves - ((token_reserves * move_reserves) / (move_value + move_reserves)) - 1
    }

    /*
    Verifies that the constant product (k) value hasn't decreased after an operation
    */
    fun verify_k_value(
        initial_meme: u64,
        initial_move: u64,
        final_meme: u64,
        final_move: u64
    ) {
        assert!(initial_meme > 0 && initial_move > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        assert!(final_meme > 0 && final_move > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        
        let initial_k = (initial_meme as u128) * (initial_move as u128);
        let final_k = (final_meme as u128) * (final_move as u128);
        
        assert!(final_k >= initial_k, ERROR_INSUFFICIENT_LIQUIDITY);
    }

    /*
    Executes a swap operation in the pool
    @param pool - Reference to the pool being operated on
    @param token_in - MEME tokens being added to the pool
    @param move_in - MOVE (AptosCoin) being added to the pool
    @param token_out_amount - Amount of MEME tokens to extract
    @param move_out_amount - Amount of MOVE (AptosCoin) to extract
    @return Tuple of (extracted MEME tokens, extracted MOVE coins)
    */
    fun swap<CoinType>(
        pool: &mut Pool<CoinType>,
        token_in: Coin<CoinType>,
        move_in: Coin<AptosCoin>,
        token_out_amount: u64,
        move_out_amount: u64
    ): (Coin<CoinType>, Coin<AptosCoin>) {
        // 1.obtain input amounts
        let token_in_amount = coin::value<CoinType>(&token_in);
        let move_in_amount = coin::value<AptosCoin>(&move_in);

        // 2. verify transaction type
        assert!(
            (token_in_amount > 0 && move_out_amount > 0) || 
            (move_in_amount > 0 && token_out_amount > 0),
            ERROR_PUMP_AMOUNT_IS_NULL
        );

        // 3. record initial reserves
        let initial_virtual_meme = pool.virtual_token_reserves;
        let initial_virtual_move = pool.virtual_move_reserves;

        // 4. process input part first
        if (token_in_amount > 0) {
            pool.virtual_token_reserves = pool.virtual_token_reserves + token_in_amount;
        };
        if (move_in_amount > 0) {
            pool.virtual_move_reserves = pool.virtual_move_reserves + move_in_amount;
        };

        // 5. process output part
        if (token_out_amount > 0) {
            assert!(
                token_out_amount <= pool.virtual_token_reserves,
                ERROR_INSUFFICIENT_LIQUIDITY
            );
            pool.virtual_token_reserves = pool.virtual_token_reserves - token_out_amount;
        };
        if (move_out_amount > 0) {
            assert!(
                move_out_amount <= pool.virtual_move_reserves,
                ERROR_INSUFFICIENT_LIQUIDITY
            );
            pool.virtual_move_reserves = pool.virtual_move_reserves - move_out_amount;
        };

        // 6. verify k value
        verify_k_value(
            initial_virtual_meme,
            initial_virtual_move,
            pool.virtual_token_reserves,
            pool.virtual_move_reserves
        );

        // 7. process real token transfer
        coin::merge<CoinType>(&mut pool.real_token_reserves, token_in);
        coin::merge<AptosCoin>(&mut pool.real_move_reserves, move_in);

        (
            coin::extract<CoinType>(&mut pool.real_token_reserves, token_out_amount),
            coin::extract<AptosCoin>(&mut pool.real_move_reserves, move_out_amount)
        )
    }

    // ========================================= Update Configuration Part ========================================
    //Update configuration
    public entry fun update_config(
        admin: &signer,
        new_platform_fee: u64,
        new_platform_fee_address: address,
        new_initial_virtual_token_reserves: u64,
        new_initial_virtual_move_reserves: u64,
        new_token_decimals: u8,
        new_dex_transfer_threshold: u64,
        new_high_fee: u64,
        new_wait_duration: u64,
        new_min_move_amount: u64
    ) acquires PumpConfig {
        //Check caller's permission
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        
        let config = borrow_global_mut<PumpConfig>(@pump);
        
        //Update configuration
        config.platform_fee = new_platform_fee;
        config.platform_fee_address = new_platform_fee_address;
        config.initial_virtual_token_reserves = new_initial_virtual_token_reserves;
        config.initial_virtual_move_reserves = new_initial_virtual_move_reserves;
        config.token_decimals = new_token_decimals;
        config.dex_transfer_threshold = new_dex_transfer_threshold;
        config.high_fee = new_high_fee;
        config.wait_duration = new_wait_duration;
        config.min_move_amount = new_min_move_amount;
    }

    //Update DEX transfer threshold
    public entry fun update_dex_threshold(
        admin: &signer,
        new_threshold: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.dex_transfer_threshold = new_threshold;
    }

    //Update platform_fee
    public entry fun update_platform_fee(
        admin: &signer,
        new_fee: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee = new_fee;
    }

    //Update platform_fee_address
    public entry fun update_platform_fee_address(
        admin: &signer,
        new_address: address
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee_address = new_address;
    }


    // ========================================= Init,deploy,buy,sell Part ========================================
    //Initialize module with admin account
    fun init_module(admin: &signer) {
        initialize(admin);
    }

    //Initialize the pump module with configuration
    //@param pump_admin - Signer with admin privileges
    public fun initialize(pump_admin: &signer) {
        assert!(address_of(pump_admin) == @pump, ERROR_NO_AUTH);
        assert!(!exists<PumpConfig>(address_of(pump_admin)), ERROR_INITIALIZED);

        let (_, signer_cap) = account::create_resource_account(pump_admin, b"pump");

        move_to(
            pump_admin,
            Handle {
                created_events: account::new_event_handle<PumpEvent>(pump_admin),
                trade_events: account::new_event_handle<TradeEvent>(pump_admin),
                transfer_events: account::new_event_handle<TransferEvent>(pump_admin),
                unfreeze_events: account::new_event_handle<UnfreezeEvent>(pump_admin)
            }
        );
        move_to(
            pump_admin,
            PumpConfig {
                platform_fee: 50,
                platform_fee_address: @pump,
                resource_cap: signer_cap,
                initial_virtual_token_reserves: 100_000_000 * DECIMALS,
                initial_virtual_move_reserves: 30 * DECIMALS,
                token_decimals: 8,
                dex_transfer_threshold: 3 * DECIMALS,
                wait_duration: 3600,      // 1 hour = 3600 seconds
                min_move_amount: 100_000_000,    // Minimum purchase amount = 100_000_000 (1 MOVE)
                high_fee: 1000,          // High fee rate period fee = 1000 (10%)
            }
        );
    }

    /* 
    Deploy a new MEME token and create its pool
    */
    entry public fun deploy<CoinType>(
        caller: &signer,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Handle {
        // Validate string lengths
        assert!(!(string::length(&description) > 1000), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&name) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&symbol) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&uri) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&website) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&telegram) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&twitter) > 100), ERROR_INVALID_LENGTH);

        // Charge 1 Move token as deployment fee
        let fee = coin::withdraw<AptosCoin>(caller, 1 * DECIMALS);
        coin::deposit(@pump, fee);

        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(!exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);

        // Initialize coin with capabilities
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(
            caller,
            name,
            symbol,
            config.token_decimals,
            true
        );

        let sender = address_of(caller);

        // Create and initialize pool
        let pool = Pool {
            real_token_reserves: coin::mint<CoinType>(
                config.initial_virtual_token_reserves,
                &mint_cap
            ),
            real_move_reserves: coin::zero<AptosCoin>(),
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_move_reserves: config.initial_virtual_move_reserves,
            token_freeze_cap: freeze_cap,
            token_burn_cap: burn_cap,
            is_completed: false,
            is_normal_dex: false,
            dev: sender
        };

        // Register coin and move pool to resource account
        coin::register<CoinType>(&resource);
        move_to(&resource, pool);

        coin::destroy_mint_cap(mint_cap);

        // Emit creation event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).created_events,
            PumpEvent {
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: config.initial_virtual_token_reserves,
                initial_virtual_move_reserves: config.initial_virtual_move_reserves,
                token_decimals: config.token_decimals,
                pool: type_name<Pool<CoinType>>(),
                dev: sender,
                description,
                name,
                symbol,
                uri,
                website,
                telegram,
                twitter
            }
        );
    }

    /// Deploy a new MEME token and immediately buy some tokens
    entry public fun deploy_and_buy<CoinType>(
        caller: &signer,
        out_amount: u64,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Pool, Handle, LastBuyer {
        deploy<CoinType>(
            caller,
            description,
            name,
            symbol,
            uri,
            website,
            telegram,
            twitter
        );
        buy<CoinType>(caller, out_amount);
    }


    //Buy MEME tokens with MOVE without slippage protection
    //@param caller - Signer buying the tokens
    //@param buy_meme_amount - Amount of MEME tokens to buy
    public entry fun buy<CoinType>(
        caller: &signer,
        buy_token_amount: u64,
    ) acquires PumpConfig, Pool, Handle, LastBuyer {
        assert!(buy_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);

        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);

        if (!coin::is_account_registered<CoinType>(sender)) {
            coin::register<CoinType>(caller);
        };
        if (!coin::is_account_registered<AptosCoin>(sender)) {
            coin::register<AptosCoin>(caller);
        };

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        if (coin::is_account_registered<CoinType>(sender) && 
            coin::is_coin_store_frozen<CoinType>(sender)) {
            coin::unfreeze_coin_store<CoinType>(sender, &pool.token_freeze_cap);
        };

        let current_move_balance = coin::value<AptosCoin>(&pool.real_move_reserves);
        
        // Check if the high fee period has started
        if (current_move_balance >= config.dex_transfer_threshold) {

            // Check if the wait duration has passed since the last buy
            if (exists<LastBuyer<CoinType>>(resource_addr)) {
                let last_buyer = borrow_global<LastBuyer<CoinType>>(resource_addr);
                let current_time = timestamp::now_seconds();
                assert!(current_time - last_buyer.timestamp < config.wait_duration, ERROR_WAIT_DURATION_PASSED);
            };

            let liquidity_cost = calculate_add_liquidity_cost(
                (pool.virtual_move_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (buy_token_amount as u256)
            );

            // Check the minimum purchase amount
            assert!((liquidity_cost as u64) >= config.min_move_amount, ERROR_AMOUNT_TOO_LOW);

            // Use high fee (10%)
            let platform_fee = math64::mul_div(
                (liquidity_cost as u64),
                config.high_fee, 
                10000
            );

            let total_cost = (liquidity_cost as u64) + platform_fee;
            let total_move_coin = coin::withdraw<AptosCoin>(caller, total_cost);
            let platform_fee_coin = coin::extract(&mut total_move_coin, platform_fee);

            let (received_token, remaining_move) = swap<CoinType>(
                pool,
                coin::zero<CoinType>(),
                total_move_coin,
                buy_token_amount,
                0
            );

            let token_amount = coin::value(&received_token);

            // Update the last buyer information
            if (exists<LastBuyer<CoinType>>(resource_addr)) {
                move_from<LastBuyer<CoinType>>(resource_addr);
            };

            // Record the new last buyer
            move_to(&resource, LastBuyer<CoinType> {
                buyer: sender,
                timestamp: timestamp::now_seconds(),
                token_amount
            });

            coin::deposit(sender, received_token);
            coin::deposit(sender, remaining_move);
            coin::deposit(config.platform_fee_address, platform_fee_coin);
            coin::freeze_coin_store(sender, &pool.token_freeze_cap);

            event::emit_event(
                &mut borrow_global_mut<Handle>(@pump).trade_events,
                TradeEvent {
                    move_amount: total_cost,
                    is_buy: true,
                    token_address: type_name<Coin<CoinType>>(),
                    token_amount,
                    user: sender,
                    virtual_move_reserves: pool.virtual_move_reserves,
                    virtual_token_reserves: pool.virtual_token_reserves,
                    timestamp: timestamp::now_seconds()
                }
            );
            return
        };

        let liquidity_cost = calculate_add_liquidity_cost(
            (pool.virtual_move_reserves as u256),
            (pool.virtual_token_reserves as u256),
            (buy_token_amount as u256)
        );

        let platform_fee = math64::mul_div(
            (liquidity_cost as u64),
            config.platform_fee,
            10000
        );

        let total_cost = (liquidity_cost as u64) + platform_fee;
        let total_move_coin = coin::withdraw<AptosCoin>(caller, total_cost);
        let platform_fee_coin = coin::extract(&mut total_move_coin, platform_fee);

        let (received_token, remaining_move) = swap<CoinType>(
            pool,
            coin::zero<CoinType>(),
            total_move_coin,
            buy_token_amount,
            0
        );

        let token_amount = coin::value(&received_token);

        coin::deposit(sender, received_token);
        coin::deposit(sender, remaining_move);
        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::freeze_coin_store(sender, &pool.token_freeze_cap);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                move_amount: total_cost,
                is_buy: true,
                token_address: type_name<Coin<CoinType>>(),
                token_amount,
                user: sender,
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //Buy MEME tokens with MOVE with slippage limit
    public entry fun buy_with_slippage<CoinType>(
        caller: &signer,
        buy_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, Pool, Handle, LastBuyer {
        let price_impact = get_price_impact<CoinType>(buy_token_amount, true);
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        buy<CoinType>(caller, buy_token_amount)
    }

    //Sell MEME tokens for MOVE with no slippage protection
    public entry fun sell<CoinType>(
        caller: &signer,
        sell_token_amount: u64
    ) acquires PumpConfig, Pool, Handle {
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);


        if (coin::is_account_registered<CoinType>(sender) && 
            coin::is_coin_store_frozen<CoinType>(sender)) {
            coin::unfreeze_coin_store<CoinType>(sender, &pool.token_freeze_cap);
        };

        assert!(
            coin::value<AptosCoin>(&pool.real_move_reserves) < config.dex_transfer_threshold,
            ERROR_NO_SELL_IN_HIGH_FEE_PERIOD
        );
        assert!(sell_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        assert!(sell_token_amount <= pool.virtual_token_reserves, ERROR_INSUFFICIENT_LIQUIDITY);

        // Check if the seller has enough token balance
        let seller_token_balance = coin::balance<CoinType>(sender);
        assert!(sell_token_amount <= seller_token_balance, ERROR_INSUFFICIENT_BALANCE);

        // Calculate MOVE amount to receive
        let liquidity_remove = calculate_sell_token(
            (pool.virtual_token_reserves as u256),
            (pool.virtual_move_reserves as u256),
            (sell_token_amount as u256)
        );

        assert!((liquidity_remove as u64) >= config.min_move_amount, ERROR_AMOUNT_TOO_LOW);
        
        let out_coin = coin::withdraw<CoinType>(caller, sell_token_amount);

        // Execute swap
        let (token, move_coin) = swap<CoinType>(
            pool,
            out_coin,
            coin::zero<AptosCoin>(),
            0,
            (liquidity_remove as u64)
        );

        // Handle platform fee
        let move_amount = coin::value(&move_coin);
        let platform_fee = math64::mul_div(move_amount, config.platform_fee, 10000);
        let platform_fee_coin = coin::extract<AptosCoin>(&mut move_coin, platform_fee);

        
        coin::deposit(sender, token);
        coin::deposit(sender, move_coin);
        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::freeze_coin_store(sender, &pool.token_freeze_cap);

        // Emit trade event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                move_amount,
                is_buy: false,
                token_address: type_name<Coin<CoinType>>(),
                token_amount: sell_token_amount,
                user: sender,
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //Sell MEME tokens for MOVE with slippage limit
    public entry fun sell_with_slippage<CoinType>(
        caller: &signer,
        sell_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, Pool, Handle {
        let price_impact = get_price_impact<CoinType>(sell_token_amount, false);
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        sell<CoinType>(caller, sell_token_amount)
    }

    // ========================================= Unfreeze Part ========================================
    //Unfreeze a user's token store after pool migration
    public entry fun unfreeze_token<CoinType>(
        caller: &signer
    ) acquires PumpConfig, Pool, Handle {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        //Check if the pool exists
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        
        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        
        //Check if the pool migration is completed
        assert!(pool.is_completed, ERROR_PUMP_NOT_COMPLETED);
        
        let sender = address_of(caller);
        coin::unfreeze_coin_store(sender, &pool.token_freeze_cap);
        
        //Emit unfreeze event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).unfreeze_events,
            UnfreezeEvent {
                token_address: type_name<Coin<CoinType>>(),
                user: sender
            }
        );
    }

    //Batch unfreeze multiple users' token stores after pool migration
    public entry fun batch_unfreeze_token<CoinType>(
        _caller: &signer,
        addresses: vector<address>
    ) acquires PumpConfig, Pool, Handle {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        //Check if the pool exists
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        
        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        
        //Check if the pool migration is completed
        assert!(pool.is_completed, ERROR_PUMP_NOT_COMPLETED);

        let handle = &mut borrow_global_mut<Handle>(@pump).unfreeze_events;
        let token_address = type_name<Coin<CoinType>>();
        
        while (!vector::is_empty(&addresses)) {
            let addr = vector::pop_back(&mut addresses);
            
            //Unfreeze the token store for the current address
            coin::unfreeze_coin_store(addr, &pool.token_freeze_cap);
            
            //Emit unfreeze event for the current address
            event::emit_event(
                handle,
                UnfreezeEvent {
                    token_address: token_address,
                    user: addr
                }
            );
        };
    }

    // ========================================= Migration Part ========================================
    // Claim migration right
    public entry fun claim_migration_right<CoinType>(
        caller: &signer
    ) acquires PumpConfig, Pool, Handle, LastBuyer {
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        
        assert!(exists<LastBuyer<CoinType>>(resource_addr), ERROR_NO_LAST_BUYER);
        let last_buyer = borrow_global<LastBuyer<CoinType>>(resource_addr);
        
        assert!(
            timestamp::now_seconds() >= last_buyer.timestamp + config.wait_duration,
            ERROR_WAIT_TIME_NOT_REACHED
        );
        
        let winner_address = last_buyer.buyer;
        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        
        if (coin::is_account_registered<CoinType>(winner_address) && 
            coin::is_coin_store_frozen<CoinType>(winner_address)) {
            coin::unfreeze_coin_store<CoinType>(winner_address, &pool.token_freeze_cap);
        };
        
        migrate_to_razor_dex<CoinType>(caller, winner_address);
    }

    /*
    Migrates the pump pool to RazorDEX
    @param caller - Signer with admin privileges
    */
    fun migrate_to_razor_dex<CoinType>(
        caller: &signer,
        winner_address: address
    ) acquires PumpConfig, Pool, Handle {
        let sender = signer::address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = signer::address_of(&resource);
        
        assert!(exists<Pool<CoinType>>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let pool = borrow_global_mut<Pool<CoinType>>(resource_addr);
        
        // Check pool is not completed
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        
        // Check if liquidity threshold is reached  
        assert!(
            coin::value(&pool.real_move_reserves) >= config.dex_transfer_threshold,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let real_move_amount = coin::value(&pool.real_move_reserves);
        let virtual_price = (pool.virtual_move_reserves as u256) * 100_000_000 / 
            (pool.virtual_token_reserves as u256);

        // Calculate required token amount based on real MOVE amount and virtual price
        let required_token_amount = ((real_move_amount as u256) * 100_000_000 / virtual_price) as u64; 
        
        pool.is_completed = true;
        if (coin::is_account_registered<CoinType>(sender) && 
            coin::is_coin_store_frozen<CoinType>(sender)) {
            coin::unfreeze_coin_store<CoinType>(sender, &pool.token_freeze_cap);
        };

        // Extract all tokens and MOVE from the pool
        let extracted_token = coin::extract_all(&mut pool.real_token_reserves);
        let extracted_move = coin::extract_all(&mut pool.real_move_reserves);

        // Extract required token amount for adding liquidity
        let token_to_dex = coin::extract(&mut extracted_token, required_token_amount);
        
        // Calculate reward for winner (10% of the remaining token)
        let reward_amount = coin::value(&extracted_token) / 10;
        let reward_token = coin::extract(&mut extracted_token, reward_amount);

        // Extract gas fee from MOVE (0.1 MOVE)
        let gas_amount = 10000000;
        let gas_coin = coin::extract(&mut extracted_move, gas_amount);
        
        if (!coin::is_account_registered<CoinType>(winner_address)) {

            coin::deposit(resource_addr, reward_token);
        } else {

            coin::deposit(winner_address, reward_token);
        };
        
        // Deposit gas fee and remaining tokens/MOVE to resource account  
        coin::deposit(resource_addr, gas_coin);
        coin::deposit(resource_addr, token_to_dex);
        coin::deposit(resource_addr, extracted_move);

        // Burn remaining tokens
        let burn_amount = coin::value(&extracted_token);
        coin::burn(extracted_token, &pool.token_burn_cap);

        // Wrap CoinType into FA token
        router::wrap_coin<CoinType>(&resource, required_token_amount);
        
        // Add liquidity to RazorDEX
        router::add_liquidity_move(
            &resource,
            type_info::account_address(&type_info::type_of<CoinType>()),  // token address
            required_token_amount,  // amountTokenDesired
            0,  // amountTokenMin
            real_move_amount - gas_amount,  // amountMoveDesired
            0,  // amountMoveMin
            resource_addr,  // to
            timestamp::now_seconds() + 10000  // deadline
        );

        // Emit transfer event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).transfer_events,
            TransferEvent {
                move_amount: real_move_amount - gas_amount,
                token_address: type_name<Coin<CoinType>>(),
                token_amount: required_token_amount,
                user: winner_address,  
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                burned_amount: burn_amount
            }
        );
    }
}