module pump::pump_fa {
    use aptos_std::simple_map::{Self, SimpleMap};

    use std::signer::address_of;
    use std::string;
    use std::string::String;
    use std::vector;
    use std::option::{Self, Option};
    use aptos_std::math64;
    use aptos_std::type_info::type_name;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::coin::Coin;
    use aptos_framework::event;
    use aptos_framework::timestamp;
    use pump::Liquid_Staking_Token;
    use razor_amm::router;

    //errors
    const ERROR_INVALID_LENGTH: u64 = 1;
    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_INITIALIZED: u64 = 3;
    const ERROR_PUMP_NOT_EXIST: u64 = 4;
    const ERROR_PUMP_COMPLETED: u64 = 5;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 6;
    const ERROR_TOKEN_DECIMAL: u64 = 7;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 8;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 9;
    const ERROR_OVERFLOW: u64 = 10;
    const ERROR_PUMP_NOT_COMPLETED: u64 = 11;
    const ERROR_EXCEED_TRANSFER_THRESHOLD: u64 = 12;
    const ERROR_BELOW_TRANSFER_THRESHOLD: u64 = 13;
    const ERROR_WAIT_DURATION_PASSED: u64 = 14;
    const ERROR_AMOUNT_TOO_LOW: u64 = 15;
    const ERROR_NO_LAST_BUYER: u64 = 16;
    const ERROR_NOT_LAST_BUYER: u64 = 17;
    const ERROR_WAIT_TIME_NOT_REACHED: u64 = 18;
    const ERROR_NO_SELL_IN_HIGH_FEE_PERIOD: u64 = 19;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 20;

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
        wait_duration: u64, // 1 hours = 3600 seconds
        min_move_amount: u64, // Minimum purchase amount = 100_000_000 (1 MOVE)
        high_fee: u64, // High fee rate period fee = 1000 (10%)
        deadline: u64
    }

    struct TokenList has key, store {
        token_list: vector<address>
    }

    struct Pool has key, store, copy, drop {
        virtual_token_reserves: u64,
        virtual_move_reserves: u64,
        is_completed: bool,
        is_normal_dex: bool,
        dev: address,
        last_buyer: Option<LastBuyer>
    }

    struct TokenPairRecord has key, store, copy {
        index: u64,
        name: String,
        symbol: String,
        pool: Pool
    }

    struct PoolRecord has key, store {
        records: SimpleMap<address, TokenPairRecord>,
        real_move_reserves: SimpleMap<address, Coin<AptosCoin>>
    }

    // struct to track the last buyer
    struct LastBuyer has store, copy, drop {
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
        token_address: address,
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
        token_address: address,
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
        assert!(
            move_reserves > 0 && token_reserves > 0 && token_amount > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        let reserve_diff = token_reserves - token_amount;
        assert!(reserve_diff > 0, ERROR_INSUFFICIENT_LIQUIDITY);
        let div_part1 = ((move_reserves * token_reserves) / reserve_diff);
        let div_part2 = ((move_reserves * token_reserves * 100) / reserve_diff);
        if (div_part1 * 100 < div_part2) {
            div_part1 = div_part1 + 1;
        };

        div_part1 - move_reserves
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
        assert!(
            token_reserves > 0 && move_reserves > 0 && token_value > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let div_part1 = (token_reserves * move_reserves) / (token_value
            + token_reserves);
        let div_part2 = (token_reserves * move_reserves * 100)
            / (token_value + token_reserves);
        if (div_part1 * 100 < div_part2) {
            div_part1 = div_part1 + 1;
        };

        move_reserves - div_part1
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
        assert!(
            token_reserves > 0 && move_reserves > 0 && move_value > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let div_part1 = (token_reserves * move_reserves) / (move_value + move_reserves);
        let div_part2 = (token_reserves * move_reserves * 100) / (
            move_value + move_reserves
        );
        if (div_part1 * 100 < div_part2) {
            div_part1 = div_part1 + 1;
        };
        token_reserves - div_part1
    }

    /*
    Verifies that the constant product (k) value hasn't decreased after an operation
    @param initial_meme - Initial MEME token reserves
    @param initial_move - Initial MOVE reserves
    @param final_meme - Final MEME token reserves
    @param final_move - Final MOVE reserves
    */
    fun verify_k_value(
        initial_meme: u64,
        initial_move: u64,
        final_meme: u64,
        final_move: u64
    ) {
        assert!(
            initial_meme > 0 && initial_move > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            final_meme > 0 && final_move > 0,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let initial_k = (initial_meme as u128) * (initial_move as u128);
        let final_k = (final_meme as u128) * (final_move as u128);

        assert!(final_k >= initial_k, ERROR_INSUFFICIENT_LIQUIDITY);
    }

    //Initialize module with admin account
    fun init_module(admin: &signer) {
        initialize(admin);
    }

    //Initialize the pump module with configuration
    //@param pump_admin - Signer with admin privileges
    public fun initialize(pump_admin: &signer) {
        assert!(address_of(pump_admin) == @pump, ERROR_NO_AUTH);
        assert!(
            !exists<PumpConfig>(address_of(pump_admin)),
            ERROR_INITIALIZED
        );

        let (resource_account, signer_cap) =
            account::create_resource_account(pump_admin, b"pump");
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
                wait_duration: 3600, // 1 hours = 3600 seconds
                min_move_amount: 100_000_000, // Minimum purchase amount = 100_000_000 (1 MOVE)
                high_fee: 1000, // High fee rate period fee = 1000 (10%)
                deadline: 10800 // 3 hours
            }
        );

        let token_list = TokenList { token_list: vector::empty() };
        move_to(&resource_account, token_list);

        let pool_record = PoolRecord {
            records: simple_map::create(),
            real_move_reserves: simple_map::create()
        };
        move_to(&resource_account, pool_record);
        coin::register<AptosCoin>(&resource_account);
    }

    #[view]
    public fun buy_token_amount(
        token_in_name: String, token_in_symbol: String, buy_token_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        let token_amount = math64::min(buy_token_amount, pool.virtual_token_reserves);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_move_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (token_amount as u256)
            );

        (liquidity_cost as u64)
    }

    #[view]
    public fun buy_move_amount(
        token_in_name: String, token_in_symbol: String, buy_move_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        (
            calculate_buy_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_move_reserves as u256),
                (buy_move_amount as u256)
            ) as u64
        )
    }

    #[view]
    public fun sell_token(
        token_in_name: String, token_in_symbol: String, sell_token_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        let liquidity_remove =
            calculate_sell_token(
                (pool.virtual_token_reserves as u256),
                (pool.virtual_move_reserves as u256),
                (sell_token_amount as u256)
            );

        (liquidity_remove as u64)
    }

    #[view]
    public fun get_current_price(
        token_in_name: String, token_in_symbol: String
    ): u64 acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let move_reserves = (pool.virtual_move_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);

        let ret_price = ((move_reserves * 100_000_000) / token_reserves);
        (ret_price as u64)
    }

    #[view]
    public fun get_pool_state(
        token_in_name: String, token_in_symbol: String
    ): (u64, u64, bool) acquires PumpConfig, PoolRecord {
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        (pool.virtual_token_reserves, pool.virtual_move_reserves, pool.is_completed)
    }

    #[view]
    public fun buy_price_with_fee(
        token_in_name: String, token_in_symbol: String, buy_meme_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let move_amount = buy_move_amount(
            token_in_name, token_in_symbol, buy_meme_amount
        );
        let platform_fee = math64::mul_div(move_amount, fee, 10000);
        move_amount + platform_fee
    }

    #[view]
    public fun sell_price_with_fee(
        token_in_name: String, token_in_symbol: String, sell_meme_amount: u64
    ): u64 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let fee = config.platform_fee;
        let move_amount = sell_token(token_in_name, token_in_symbol, sell_meme_amount);
        let platform_fee = math64::mul_div(move_amount, fee, 10000);
        move_amount - platform_fee
    }

    #[view]
    public fun get_price_impact(
        token_in_name: String,
        token_in_symbol: String,
        amount: u64,
        is_buy: bool
    ): u64 acquires PumpConfig, PoolRecord {
        if (amount == 0) {
            return 0
        };
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);

        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;
        let move_reserves = (pool.virtual_move_reserves as u256);
        let token_reserves = (pool.virtual_token_reserves as u256);
        let amount_256 = (amount as u256);

        if (token_reserves == 0 || move_reserves == 0) {
            return 0
        };

        let initial_price = (move_reserves * 100_000_000) / token_reserves;

        let final_price =
            if (is_buy) {
                let move_in =
                    calculate_add_liquidity_cost(
                        move_reserves, token_reserves, amount_256
                    );
                let new_move = move_reserves + move_in;
                let new_token = token_reserves - amount_256;
                if (new_token == 0) {
                    return 10000 // 100% impact
                };
                (new_move * 100_000_000) / new_token
            } else {
                let move_out =
                    calculate_sell_token(token_reserves, move_reserves, amount_256);
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

        let price_diff =
            if (final_price > initial_price) {
                (final_price - initial_price) * 10000
            } else {
                (initial_price - final_price) * 10000
            };

        ((price_diff / initial_price) as u64)
    }

    // Get last buyer information
    #[view]
    public fun get_last_buyer(
        token_in_name: String,
        token_in_symbol: String
    ): (address, u64, u64) acquires PumpConfig, PoolRecord {
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        
        let pool_record = borrow_global<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow(&pool_record.records, &token_addr);
        let pool = token_pair_record.pool;
        
        if (option::is_none(&pool.last_buyer)) {
            return (@0x0, 0, 0)
        };
        
        let last_buyer = option::borrow(&pool.last_buyer);
        (
            last_buyer.buyer,
            last_buyer.timestamp + config.wait_duration,
            last_buyer.token_amount
        )
    }

    // Get current pump stage
    #[view]
    public fun get_pump_stage(
        token_in_name: String,
        token_in_symbol: String
    ): u8 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        
        let pool_record = borrow_global<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow(&pool_record.records, &token_addr);
        let pool = token_pair_record.pool;
        
        // Stage 4: Pool completed
        if (pool.is_completed) {
            return 4
        };
        
        let real_move_reserves = simple_map::borrow(&pool_record.real_move_reserves, &token_addr);
        let current_move_balance = coin::value<AptosCoin>(real_move_reserves);

        // Stage 1: Before reaching threshold
        if (current_move_balance < config.dex_transfer_threshold) {
            return 1
        };

        // Stage 2: After threshold but before wait duration
        if (option::is_some(&pool.last_buyer)) {
            let last_buyer = option::borrow(&pool.last_buyer);
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

    /*
    Deploy a new MEME token and create its pool
    */
    public entry fun deploy(
        caller: &signer,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String
    ) acquires PumpConfig, Handle, TokenList, PoolRecord {
        // Validate string lengths
        assert!(!(string::length(&description) > 1000), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&name) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&symbol) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&uri) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&website) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&telegram) > 100), ERROR_INVALID_LENGTH);
        assert!(!(string::length(&twitter) > 100), ERROR_INVALID_LENGTH);

        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let sender = address_of(caller);

        Liquid_Staking_Token::create_fa(
            name,
            symbol,
            config.token_decimals,
            uri,
            website
        );
        let token_list = borrow_global_mut<TokenList>(resource_addr);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);

        // Create and initialize pool
        let pool = Pool {
            virtual_token_reserves: config.initial_virtual_token_reserves,
            virtual_move_reserves: config.initial_virtual_move_reserves,
            is_completed: false,
            is_normal_dex: false,
            dev: sender,
            last_buyer: option::none()
        };

        let token_pair_record = TokenPairRecord {
            index: vector::length(&token_list.token_list),
            name: name,
            symbol: symbol,
            pool
        };

        let token_address = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        simple_map::add(&mut pool_record.records, token_address, token_pair_record);
        simple_map::add(
            &mut pool_record.real_move_reserves, token_address, coin::zero<AptosCoin>()
        );

        vector::push_back(&mut token_list.token_list, token_address);

        // Emit creation event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).created_events,
            PumpEvent {
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: config.initial_virtual_token_reserves,
                initial_virtual_move_reserves: config.initial_virtual_move_reserves,
                token_decimals: config.token_decimals,
                pool: type_name<Pool>(),
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

    fun get_token_by_apt(
        pool: &mut Pool, move_in_amount: u64, token_out_amount: u64
    ) {
        assert!(
            token_out_amount <= pool.virtual_token_reserves,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        let initial_virtual_token = pool.virtual_token_reserves;
        let initial_virtual_move = pool.virtual_move_reserves;
        if (move_in_amount > 0) {
            pool.virtual_move_reserves = pool.virtual_move_reserves + move_in_amount;
        };

        pool.virtual_token_reserves = pool.virtual_token_reserves - token_out_amount;

        verify_k_value(
            initial_virtual_token,
            initial_virtual_move,
            pool.virtual_token_reserves,
            pool.virtual_move_reserves
        );
    }

    //Buy MEME tokens with MOVE without slippage protection
    //@param caller - Signer buying the tokens
    //@param token_addr - FA tokens address
    //@param buy_meme_amount - Amount of MEME tokens to buy
    public entry fun buy(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        buy_token_amount: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(buy_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);
        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);

        if (!coin::is_account_registered<AptosCoin>(sender)) {
            coin::register<AptosCoin>(caller);
        };

        let resource = account::create_signer_with_capability(&config.resource_cap);
        let resource_addr = address_of(&resource);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow_mut<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let real_move_reserves =
            simple_map::borrow_mut<address, Coin<AptosCoin>>(
                &mut pool_record.real_move_reserves, &token_addr
            );
        let current_move_balance = coin::value(real_move_reserves);

        // Check if the high fee period has started
        if (current_move_balance >= config.dex_transfer_threshold) {
            // Check if the wait duration has passed since the last buy
            if (option::is_some(&pool.last_buyer)) {
                let last_buyer = option::borrow(&pool.last_buyer);
                let current_time = timestamp::now_seconds();
                assert!(
                    current_time - last_buyer.timestamp < config.wait_duration,
                    ERROR_WAIT_DURATION_PASSED
                );
            };

            let liquidity_cost =
                calculate_add_liquidity_cost(
                    (pool.virtual_move_reserves as u256),
                    (pool.virtual_token_reserves as u256),
                    (buy_token_amount as u256)
                );

            // Check the minimum purchase amount
            assert!(
                (liquidity_cost as u64) >= config.min_move_amount, ERROR_AMOUNT_TOO_LOW
            );

            // Use high fee (10%)
            let platform_fee =
                math64::mul_div((liquidity_cost as u64), config.high_fee, 10000);

            let total_cost = (liquidity_cost as u64) + platform_fee;
            let total_move_coin = coin::withdraw<AptosCoin>(caller, total_cost);
            let platform_fee_coin = coin::extract(&mut total_move_coin, platform_fee);

            let move_in_amount = coin::value<AptosCoin>(&total_move_coin);
            get_token_by_apt(&mut pool, move_in_amount, buy_token_amount);
            coin::merge<AptosCoin>(real_move_reserves, total_move_coin);

            // Update the last buyer information
            if (option::is_some(&pool.last_buyer)) {
                let _last_buyer = option::borrow(&pool.last_buyer);
                // Clean up previous records
            };

            // Record the new last buyer
            pool.last_buyer = option::some(LastBuyer {
                buyer: sender,
                timestamp: timestamp::now_seconds(),
                token_amount: buy_token_amount
            });

            Liquid_Staking_Token::mint(
                sender,
                buy_token_amount,
                token_pair_record.name,
                token_pair_record.symbol
            );
            coin::deposit(config.platform_fee_address, platform_fee_coin);

            event::emit_event(
                &mut borrow_global_mut<Handle>(@pump).trade_events,
                TradeEvent {
                    move_amount: move_in_amount,
                    is_buy: true,
                    token_address: token_addr,
                    token_amount: buy_token_amount,
                    user: sender,
                    virtual_move_reserves: pool.virtual_move_reserves,
                    virtual_token_reserves: pool.virtual_token_reserves,
                    timestamp: timestamp::now_seconds()
                }
            );
            token_pair_record.pool = pool;
            return
        };

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_move_reserves as u256),
                (pool.virtual_token_reserves as u256),
                (buy_token_amount as u256)
            );

        // Check the minimum purchase amount
        assert!((liquidity_cost as u64) >= 10000, ERROR_AMOUNT_TOO_LOW);
        
        let platform_fee =
            math64::mul_div(
                (liquidity_cost as u64),
                config.platform_fee,
                10000
            );

        let total_cost = (liquidity_cost as u64) + platform_fee;
        let total_move_coin = coin::withdraw<AptosCoin>(caller, total_cost);
        let platform_fee_coin = coin::extract(&mut total_move_coin, platform_fee);

        let move_in_amount = coin::value<AptosCoin>(&total_move_coin);

        // Check if this buy will trigger the high fee period
        let will_trigger_high_fee = current_move_balance < config.dex_transfer_threshold && 
            (current_move_balance + move_in_amount) >= config.dex_transfer_threshold;

        // If this buy will trigger high fee period, record this buyer as LastBuyer
        if (will_trigger_high_fee) {
            if (option::is_some(&pool.last_buyer)) {
                let _last_buyer = option::borrow(&pool.last_buyer);
            };
            pool.last_buyer = option::some(LastBuyer {
                buyer: sender,
                timestamp: timestamp::now_seconds(),
                token_amount: buy_token_amount
            });
        };
        
        get_token_by_apt(&mut pool, move_in_amount, buy_token_amount);

        coin::merge<AptosCoin>(real_move_reserves, total_move_coin);

        Liquid_Staking_Token::mint(
            sender,
            buy_token_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );
        coin::deposit(config.platform_fee_address, platform_fee_coin);

        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                move_amount: total_cost,
                is_buy: true,
                token_address: token_addr,
                token_amount: buy_token_amount,
                user: sender,
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
        token_pair_record.pool = pool;
    }

    //Buy MEME tokens with MOVE with slippage limit
    //@param caller - Signer buying the tokens
    //@param token_addr - FA tokens address
    //@param buy_token_amount - Amount of MEME tokens to buy
    //@param max_price_impact - Maximum price impact allowed
    public entry fun buy_with_slippage(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        buy_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        let price_impact =
            get_price_impact(
                token_in_name,
                token_in_symbol,
                buy_token_amount,
                true
            );
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        buy(
            caller,
            token_in_name,
            token_in_symbol,
            buy_token_amount
        )
    }

    fun get_apt_by_token(
        pool: &mut Pool, token_in_amount: u64, move_out_amount: u64
    ) {
        assert!(
            move_out_amount <= pool.virtual_move_reserves,
            ERROR_INSUFFICIENT_LIQUIDITY
        );
        assert!(
            token_in_amount > 0 && move_out_amount > 0,
            ERROR_PUMP_AMOUNT_IS_NULL
        );
        let initial_virtual_token = pool.virtual_token_reserves;
        let initial_virtual_move = pool.virtual_move_reserves;

        if (token_in_amount > 0) {
            pool.virtual_token_reserves = pool.virtual_token_reserves + token_in_amount;
        };

        pool.virtual_move_reserves = pool.virtual_move_reserves - move_out_amount;

        verify_k_value(
            initial_virtual_token,
            initial_virtual_move,
            pool.virtual_token_reserves,
            pool.virtual_move_reserves
        );
    }

    //Sell MEME tokens for MOVE with no slippage protection
    //@param caller - Signer selling the tokens
    //@param sell_token_amount - Amount of MEME tokens to sell
    public entry fun sell(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        sell_token_amount: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(sell_token_amount > 0, ERROR_PUMP_AMOUNT_IS_NULL);

        let token_addr =
            Liquid_Staking_Token::get_fa_obj_address(token_in_name, token_in_symbol);
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_addr
            );
        let pool = token_pair_record.pool;

        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);
        assert!(
            sell_token_amount <= pool.virtual_token_reserves,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        // Add balance check
        let token_balance = Liquid_Staking_Token::get_balance(
            sender,
            token_pair_record.name,
            token_pair_record.symbol
        );
        assert!(sell_token_amount <= token_balance, ERROR_INSUFFICIENT_BALANCE);

        let real_move_reserves =
            simple_map::borrow_mut<address, Coin<AptosCoin>>(
                &mut pool_record.real_move_reserves, &token_addr
            );
        let current_move_balance = coin::value(real_move_reserves);

        assert!(
            current_move_balance < config.dex_transfer_threshold,
            ERROR_NO_SELL_IN_HIGH_FEE_PERIOD
        );

        // Calculate MOVE amount to receive
        let liquidity_remove =
            (
                calculate_sell_token(
                    (pool.virtual_token_reserves as u256),
                    (pool.virtual_move_reserves as u256),
                    (sell_token_amount as u256)
                ) as u64
            );

        // Check the minimum purchase amount
        assert!((liquidity_remove as u64) >= 10000, ERROR_AMOUNT_TOO_LOW);

        Liquid_Staking_Token::burn(
            sender,
            sell_token_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );

        // Execute swap
        get_apt_by_token(&mut pool, sell_token_amount, liquidity_remove);

        // Handle platform fee
        let platform_fee = math64::mul_div(liquidity_remove, config.platform_fee, 10000);
        let move_to_user = coin::extract<AptosCoin>(
            real_move_reserves, liquidity_remove
        );
        let move_amount = coin::value<AptosCoin>(&move_to_user);
        let platform_fee_coin = coin::extract<AptosCoin>(&mut move_to_user, platform_fee);

        // Distribute coins
        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::deposit(sender, move_to_user);

        // Emit trade event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).trade_events,
            TradeEvent {
                move_amount,
                is_buy: false,
                token_address: token_addr,
                token_amount: sell_token_amount,
                user: sender,
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    //Sell MEME tokens for MOVE with slippage limit
    //@param caller - Signer selling the tokens
    //@param sell_token_amount - Amount of MEME tokens to sell
    //@param max_price_impact - Maximum price impact allowed
    public entry fun sell_with_slippage(
        caller: &signer,
        token_in_name: String,
        token_in_symbol: String,
        sell_token_amount: u64,
        max_price_impact: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        let price_impact =
            get_price_impact(
                token_in_name,
                token_in_symbol,
                sell_token_amount,
                false
            );
        assert!(price_impact <= max_price_impact, ERROR_SLIPPAGE_TOO_HIGH);
        sell(
            caller,
            token_in_name,
            token_in_symbol,
            sell_token_amount
        )
    }

    //Update configuration
    //@param admin - Admin signer with permission to update config
    //@param new_platform_fee - New platform fee rate (in basis points)
    //@param new_platform_fee_address - New address to receive platform fees
    //@param new_initial_virtual_token_reserves - New initial virtual token reserves
    //@param new_initial_virtual_move_reserves - New initial virtual MOVE reserves
    //@param new_token_decimals - New token decimals
    //@param new_dex_transfer_threshold - New threshold for DEX transfer
    //@param new_high_fee - New high fee rate (in basis points)
    //@param new_wait_duration - New wait duration in seconds
    //@param new_min_move_amount - New minimum MOVE amount for purchases
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
        new_min_move_amount: u64,
        new_deadline: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);

        config.platform_fee = new_platform_fee;
        config.platform_fee_address = new_platform_fee_address;
        config.initial_virtual_token_reserves = new_initial_virtual_token_reserves;
        config.initial_virtual_move_reserves = new_initial_virtual_move_reserves;
        config.token_decimals = new_token_decimals;
        config.dex_transfer_threshold = new_dex_transfer_threshold;
        config.high_fee = new_high_fee;
        config.wait_duration = new_wait_duration;
        config.min_move_amount = new_min_move_amount;
        config.deadline = new_deadline;
    }

    //Update DEX transfer threshold
    //@param admin - Admin signer with permission to update threshold
    //@param new_threshold - New threshold value for DEX transfer
    public entry fun update_dex_threshold(
        admin: &signer, new_threshold: u64
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.dex_transfer_threshold = new_threshold;
    }

    //Update platform fee rate
    //@param admin - Admin signer with permission to update fee
    //@param new_fee - New platform fee rate (in basis points)
    public entry fun update_platform_fee(admin: &signer, new_fee: u64) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee = new_fee;
    }

    //Update platform fee receiving address
    //@param admin - Admin signer with permission to update address
    //@param new_address - New address to receive platform fees
    public entry fun update_platform_fee_address(
        admin: &signer, new_address: address
    ) acquires PumpConfig {
        assert!(address_of(admin) == @pump, ERROR_NO_AUTH);
        let config = borrow_global_mut<PumpConfig>(@pump);
        config.platform_fee_address = new_address;
    }

    // ========================================= Migration Part ========================================
    // Claim migration right
    public entry fun claim_migration_right(
        caller: &signer,
        name: String,
        symbol: String
    ) acquires PumpConfig, PoolRecord, Handle {
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), ERROR_PUMP_NOT_EXIST);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow_mut<address, TokenPairRecord>(
            &mut pool_record.records, &token_addr
        );

        assert!(option::is_some(&token_pair_record.pool.last_buyer), ERROR_NO_LAST_BUYER);
        let last_buyer = option::borrow(&token_pair_record.pool.last_buyer);

        assert!(
            timestamp::now_seconds() >= last_buyer.timestamp + config.wait_duration,
            ERROR_WAIT_TIME_NOT_REACHED
        );

        let winner_address = last_buyer.buyer;
        let real_move_reserves = simple_map::borrow_mut<address, Coin<AptosCoin>>(
            &mut pool_record.real_move_reserves, &token_addr
        );
        migrate_to_razor_dex(
            caller,
            name,
            symbol,
            token_pair_record,
            real_move_reserves,
            winner_address
        );
    }

    /*
    Migrates the pump pool to razor DEX
    */
    fun migrate_to_razor_dex(
        caller: &signer,
        name: String, 
        symbol: String,
        token_pair_record: &mut TokenPairRecord,
        real_move_reserves: &mut Coin<AptosCoin>,
        winner_address: address
    ) acquires PumpConfig, Handle {
        let sender = address_of(caller);
        let token_addr = Liquid_Staking_Token::get_fa_obj_address(name, symbol);
        let config = borrow_global<PumpConfig>(@pump);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let resource_signer = account::create_signer_with_capability(&config.resource_cap);

        let pool = token_pair_record.pool;

        // check pool is not completed
        assert!(!pool.is_completed, ERROR_PUMP_COMPLETED);

        let real_move_amount = coin::value<AptosCoin>(real_move_reserves);

        // check if migration threshold is reached
        assert!(
            real_move_amount >= config.dex_transfer_threshold,
            ERROR_INSUFFICIENT_LIQUIDITY
        );

        let virtual_price = 
            (pool.virtual_move_reserves as u256) * 100_000_000 
                / (pool.virtual_token_reserves as u256);

        let required_token = (((real_move_amount as u256) * 100_000_000 / virtual_price) as u64);
        let burned_amount = pool.virtual_token_reserves - required_token;
        pool.is_completed = true;

        // Calculate reward for winner (10% of the token amount)
        let reward_amount = pool.virtual_token_reserves / 10;

        // Send reward to winner
        Liquid_Staking_Token::mint(
            winner_address,
            reward_amount,
            token_pair_record.name,
            token_pair_record.symbol
        );

        // Extract gas fee from move coins (0.1 MOVE = 10000000 octa)
        let gas_amount = 10000000;
        let gas_coin = coin::extract<AptosCoin>(real_move_reserves, gas_amount);

        // Store gas fee in resource account
        coin::deposit(resource_addr, gas_coin);

        // Store tokens in resource account
        let real_move_amount = coin::value<AptosCoin>(real_move_reserves);
        let real_move = coin::extract<AptosCoin>(real_move_reserves, real_move_amount);
        coin::deposit<AptosCoin>(resource_addr, real_move);

        // should mint required_token to dex
        Liquid_Staking_Token::mint(
            resource_addr,
            required_token,
            token_pair_record.name,
            token_pair_record.symbol
        );

        router::add_liquidity_move(
            &resource_signer,
            // token: address,
            token_addr,
            // amount_token_desired: u64,
            required_token,
            // amount_token_min: u64,
            0,
            // amount_move_desired: u64,
            real_move_amount,  // Removed gas_amount subtraction
            // amount_move_min: u64,
            0,
            // to: address,
            resource_addr,
            // deadline: u64,
            timestamp::now_seconds() + config.deadline
        );

        // Emit transfer event
        event::emit_event(
            &mut borrow_global_mut<Handle>(@pump).transfer_events,
            TransferEvent {
                move_amount: real_move_amount,
                token_address: token_addr,
                token_amount: required_token,
                user: sender,
                virtual_move_reserves: pool.virtual_move_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                burned_amount
            }
        );
        token_pair_record.pool = pool;
    }

    #[test_only]
    use aptos_framework::aptos_coin;

    #[test_only]
    const ONE_APT: u64 = 100000000; // 1x10**8

    #[test_only]
    public fun create_test_accounts(
        deployer: &signer, user_1: &signer, user_2: &signer
    ) {
        account::create_account_for_test(address_of(user_1));
        account::create_account_for_test(address_of(user_2));
        account::create_account_for_test(address_of(deployer));
        coin::register<AptosCoin>(user_1);
        coin::register<AptosCoin>(user_2);
        coin::register<AptosCoin>(deployer);
    }

    #[test_only]
    public fun test_init_only(creator: &signer) {
        init_module(creator);
    }

    #[test(
        aptos_framework = @0x1, sender = @pump, user1 = @0x123, user2 = @0x1234
    )]
    public fun test_buy(
        aptos_framework: &signer,
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires PumpConfig, Handle, TokenList, PoolRecord {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        create_test_accounts(sender, user1, user2);

        test_init_only(sender);
        Liquid_Staking_Token::test_init_only(sender);

        aptos_coin::mint(aptos_framework, address_of(user1), 200 * ONE_APT);
        aptos_coin::mint(aptos_framework, address_of(user2), 200 * ONE_APT);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        deploy(
            sender,
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            string::utf8(b"http://telegram.com"),
            string::utf8(b"http://twitter.com")
        );
        buy(
            user1, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            4_000_000 * DECIMALS // buy_token_amount: u64
        );
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        aptos_framework = @0x1, sender = @pump, user1 = @0x123, user2 = @0x1234
    )]
    public fun test_sell(
        aptos_framework: &signer,
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires PumpConfig, Handle, TokenList, PoolRecord {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        create_test_accounts(sender, user1, user2);

        test_init_only(sender);
        Liquid_Staking_Token::test_init_only(sender);

        aptos_coin::mint(aptos_framework, address_of(user1), 200 * ONE_APT);
        aptos_coin::mint(aptos_framework, address_of(user2), 200 * ONE_APT);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        deploy(
            sender,
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            string::utf8(b"http://telegram.com"),
            string::utf8(b"http://twitter.com")
        );
        buy(
            user1, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            5_000_000 * DECIMALS // buy_token_amount: u64  -- cost 1.5 APT
        );

        let user1_meme_balance = Liquid_Staking_Token::get_balance(address_of(user1), string::utf8(b"meme"), string::utf8(b"meme"));
        assert!(
            user1_meme_balance == (5_000_000 * DECIMALS),
            2
        ); // 5_000_000 * DECIMALS meme coin


        let user1_balance = coin::balance<AptosCoin>(address_of(user1));
        assert!(user1_balance == 19841315790, user1_balance);

        sell(
            // caller: &signer,
            user1,
            // token_in_name: String,
            string::utf8(b"meme"),
            // token_in_symbol: String,
            string::utf8(b"meme"),
            // sell_token_amount: u64
            4_000_000 * DECIMALS //  -- get 1.2 APT
        );

        let user1_balance = coin::balance<AptosCoin>(address_of(user1));
        assert!(user1_balance == 19968269538, user1_balance);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(
        aptos_framework = @0x1, sender = @pump, user1 = @0x123, user2 = @0x1234
    )]
    public fun test_migrate_to_dex(
        aptos_framework: &signer,
        sender: &signer,
        user1: &signer,
        user2: &signer
    ) acquires PumpConfig, Handle, TokenList, PoolRecord {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        create_test_accounts(sender, user1, user2);

        test_init_only(sender);
        Liquid_Staking_Token::test_init_only(sender);

        aptos_coin::mint(aptos_framework, address_of(user1), 200 * ONE_APT);
        aptos_coin::mint(aptos_framework, address_of(user2), 200 * ONE_APT);
        timestamp::set_time_has_started_for_testing(aptos_framework);

        deploy(
            sender,
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"meme"),
            string::utf8(b"http://example.com/favicon.ico"),
            string::utf8(b"http://example.com"),
            string::utf8(b"http://telegram.com"),
            string::utf8(b"http://twitter.com")
        );

        // --------------------------------------
        buy(
            user1, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            5_000_000 * DECIMALS // buy_token_amount: u64  -- cost 1.5 APT
        );

        let user1_meme_balance = Liquid_Staking_Token::get_balance(address_of(user1), string::utf8(b"meme"), string::utf8(b"meme"));
        assert!(
            user1_meme_balance == (5_000_000 * DECIMALS),
            2
        ); // 5_000_000 * DECIMALS meme coin


        // --------------------------------------
        buy(
            user2, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            5_000_000 * DECIMALS // buy_token_amount: u64  -- cost 1.5 APT
        );
        buy(
            user1, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            5_000_000 * DECIMALS // buy_token_amount: u64  -- cost 1.5 APT
        );        

        let user1_meme_balance = Liquid_Staking_Token::get_balance(address_of(user1), string::utf8(b"meme"), string::utf8(b"meme"));
        assert!(
            user1_meme_balance == (10_000_000 * DECIMALS),
            user1_meme_balance
        );

        // --------------------------------------
        // enter high fee period, but pool.virtual_token_reserves > 20_000_000 * DECIMALS
        buy(
            user2, // caller: &signer,
            string::utf8(b"meme"), // token_in_name: String,
            string::utf8(b"meme"), // token_in_symbol: String,
            4_000_000 * DECIMALS // buy_token_amount: u64  -- cost 1.2 APT
        );
        let user2_meme_balance = Liquid_Staking_Token::get_balance(address_of(user2), string::utf8(b"meme"), string::utf8(b"meme"));
        assert!(
            user2_meme_balance == (9_000_000 * DECIMALS),
            user2_meme_balance
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
