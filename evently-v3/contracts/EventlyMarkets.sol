// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { SD59x18, add, div, exp, ln, mul, wrap, unwrap } from "@prb/math/src/SD59x18.sol";

/// @title EventlyMarkets
/// @author evently Team (evently.market · @eventlymarket)
/// @notice Fully on-chain prediction markets with tradable ERC-1155 positions,
///         LMSR AMM (b=200 USDm) + Central Limit Order Book (bids & asks).
///
///   BUYING: placeOrder(BUY, price, qty) — CLOB ask orders filled first (price-time priority);
///           remaining budget routed to the LMSR AMM as market maker of last resort.
///
///   SELLING: placeOrder(SELL, price, qty) — shares escrowed, CLOB bids matched first;
///            or sellToAMM() for instant AMM execution with mandatory slippage guard.
///
///   CLOB: Central Limit Order Book — bids AND asks, matched automatically on placement.
///         Price-time priority. Max 200 orders per (market, option, side); max 10 per user per market.
///
///   AMM: LMSR with b = 200 USDm. Permanent market maker. Solvency guaranteed by construction.
///        Initial subsidy = b * ln(n_options) locked by creator at market creation.
///
///   RESOLUTION: Winning shares redeemable for exactly 1 USDm per share after finalization.
///               Mandatory evidence hash on every resolution. Losing shares burned 24h after finalization.
///
///   DISPUTES: Any market participant may dispute (50 USDm collateral, waived for admin).
///             Settled by dedicated disputeResolver role. Monthly lottery for successful disputers.
///
///   FEES: 2.5% fixed per trade (creator 1%, treasury 1%, resolver pool 0.5%). Hardcoded constants.
///
///   COLLATERAL: 50 USDm locked by creator, returned on honest resolution.
///               Slashed to treasury on dishonest resolution or admin slash.
///
///   EMERGENCY: 72h auto-expiry pause, address ban, admin cancel orders.
///              Treasury and resolver pool changes timelocked 24h.
///
///   Token ID encoding: marketId * MAX_OPTIONS + optionIndex

contract EventlyMarkets is ERC1155 {
    using SafeERC20 for IERC20;

    // ──────────────────────────── Constants ────────────────────────────
    uint256 public constant CREATOR_COLLATERAL  = 50e18;
    uint256 public constant IMPORT_FEE           = 10e18;  // one-time fee paid to treasury on import
    uint256 public constant DISPUTE_COLLATERAL  = 50e18;
    uint256 public constant DISPUTE_WINDOW      = 24 hours;
    uint256 public constant BURN_DELAY          = 24 hours; // after finalization
    uint256 public constant MAX_OPTIONS         = 4;
    uint256 public constant MIN_OPTIONS         = 2;
    // LMSR liquidity parameter b = 200 USDm
    uint256 public constant LMSR_B     = 200e18;
    uint256 public constant SHARE_UNIT = 1e18;   // 1 share = 1e18 = 1 USDm payout
    uint256 public constant MIN_TRADE  = 1e15;   // 0.001 shares minimum

    // CLOB: max resting orders per (market, option, side) — griefing cap (A-03 / F-DS-M02)
    uint256 public constant MAX_ORDERS_PER_BOOK = 200;
    // Max active resting orders a single address may hold on one market (all options + sides combined)
    uint256 public constant MAX_ORDERS_PER_USER = 10;

    // Minimum betting window prevents creator-controlled flash markets (BIZ-06)
    uint256 public constant MIN_BETTING_WINDOW = 1 hours;

    // Buffer added to dispute window before finalization is allowed (ATCK-07: sequencer timestamp guard)
    uint256 public constant FINALIZE_BUFFER = 1 hours;

    // Minimum value of any order in USDm — prevents CLOB griefing with dust orders (ATCK-06)
    uint256 public constant MIN_ORDER_VALUE = 1e18; // 1 USDm

    // Delay before a requested treasury withdrawal can be executed (AC-03: rug-pull prevention)
    uint256 public constant TREASURY_WITHDRAWAL_DELAY = 24 hours;

    // Maximum duration a pause can remain active before anyone can force-unpause
    uint256 public constant MAX_PAUSE_DURATION = 72 hours;

    // Monthly dispute lottery: 30% of treasury gains from successful disputes
    uint256 public constant DISPUTE_REWARD_SHARE_BPS = 3000;
    uint256 public constant DISPUTE_MONTH_DURATION   = 30 days;

    // PRBMath SD59x18: exp(x) reverts for x > this value (fix MATH-02)
    int256 private constant EXP_MAX_ARG = 133_084258667509499441;

    // REX4: minimum gasleft() required before attempting an external call inside a loop.
    // Each inner CALL frame gets remaining × 98/100; at depth-3 that is ~0.9604 × parent.
    // 80_000 covers: ERC20 safeTransfer (~35k) + ERC1155 safeTransferFrom (~50k) + overhead.
    uint256 private constant REX4_MIN_GAS_PER_ITER = 80_000;

    // ──────────────────────────── Enums ────────────────────────────────
    enum MarketStatus { Active, BettingClosed, Resolved, Disputed, Finalized, Cancelled, Slashed }
    enum Category     { Crypto, Politics, Fun, Technology, Business, Science, World, Entertainment, PopCulture }
    enum OrderSide    { BUY, SELL }

    // ──────────────────────────── Structs ──────────────────────────────
    struct Market {
        address   creator;
        string    question;
        string[]  options;
        Category  category;
        string    resolutionCriteria;
        string    imageUrl;

        uint256 bettingDeadline;
        uint256 resolutionDeadline;
        uint256 createdAt;

        MarketStatus status;
        uint256 winningOption;
        uint256 resolvedAt;
        uint256 finalizedAt;

        // Dispute
        address disputer;
        uint256 disputeOption;
        bool    disputerPaidCollateral; // false when admin disputes (security function, no collateral)

        // LMSR state
        uint256[] quantities;       // shares outstanding per option
        uint256   b;                // LMSR liquidity parameter (= LMSR_B)
        uint256   subsidyDeposited; // b * ln(n) locked at creation

        // Accounting
        uint256 poolBalance;  // USDm backing AMM shares
        uint256 totalVolume;  // cumulative volume (display)

        // Flags
        bool creatorCollateralReturned;
        bool creatorFeePaid;
        bool isAdminMarket;
        bool isImportedMarket;   // imported from Polymarket — reduced collateral + 0.5% creator fee
        bool losingSharesBurned;

        // Polymarket reference (for imported markets — duplicate prevention)
        string pmConditionId;
    }

    /// @dev A resting CLOB limit order
    struct Order {
        address   maker;
        uint256   marketId;
        uint256   optionIndex;
        OrderSide side;
        uint256   pricePerShare;     // USDm per share, 18 dec — 0 < price < 1e18
        uint256   quantityRemaining; // shares remaining
        uint256   usdmEscrowed;      // USDm held for BUY orders; 0 for SELL orders
        bool      active;
        uint256   placedAt;          // timestamp — for FIFO within same price level
    }

    // ──────────────────────────── State ────────────────────────────────
    address public admin;
    address public pendingAdmin; // two-step transfer (fix AC-02)
    IERC20  public usdm;
    bool    public whitelistEnabled;

    // Treasury withdrawal delay state (AC-03)
    address public pendingWithdrawalTo;
    uint256 public pendingWithdrawalAmount;
    uint256 public pendingWithdrawalReadyAt;

    mapping(address => bool) public whitelisted;
    uint256 public whitelistedCount;
    mapping(address => bool) public banned;
    // Separate right to CREATE markets (subset of whitelisted traders)
    mapping(address => bool) public marketCreatorWhitelisted;
    mapping(bytes32 => bool) public inviteCodeUsed;
    mapping(bytes32 => bool) public inviteCodeValid;

    // Participation tracking for dispute eligibility (set on any trade or order)
    mapping(uint256 => mapping(address => bool)) public hasParticipated;

    // Monthly dispute lottery
    mapping(uint256 => uint256)   public monthlyDisputePool;
    mapping(uint256 => address[]) internal _monthlyDisputers;
    mapping(uint256 => bool)      public monthlyRewardsDistributed;

    // ── Fees (basis points, 1 bps = 0.01%) — fixed, not configurable ──
    uint256 public constant creatorFeeBps         = 100; // 1.00%  — regular markets
    uint256 public constant importedCreatorFeeBps = 50;  // 0.50%  — imported markets (extra 50bps → treasury)
    uint256 public constant treasuryFeeBps        = 100; // 1.00%
    uint256 public constant resolverFeeBps        = 50;  // 0.50%

    // Duplicate prevention: pm_condition_id → already imported
    mapping(bytes32 => bool) public pmConditionImported;

    // ── Resolver pool ──
    address public resolverPoolAddress;
    uint256 public resolverPoolBalance;
    address public pendingResolverPoolAddress;
    uint256 public pendingResolverPoolReadyAt;

    // Separate role for dispute settlement — independent from admin multisig
    address public disputeResolver;

    uint256 public nextMarketId;
    mapping(uint256 => Market) internal _markets;
    uint256 public treasuryBalance;

    // ── Community upvotes ──
    // Each address can upvote a given market once. Vote count used for trending ranking.
    mapping(uint256 => uint256) public upvoteCount;
    mapping(uint256 => mapping(address => bool)) public hasUpvoted;

    // ── CLOB order store ──
    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    // Bid book: marketId → optionIndex → order IDs sorted highest price first (FIFO within price)
    mapping(uint256 => mapping(uint256 => uint256[])) internal _bidBook;
    // Ask book: marketId → optionIndex → order IDs sorted lowest price first (FIFO within price)
    mapping(uint256 => mapping(uint256 => uint256[])) internal _askBook;

    // Total minted shares per option (for redemption / cancel refund math)
    mapping(uint256 => mapping(uint256 => uint256)) public optionSupply;

    // Active resting order count per (marketId, maker) — enforces MAX_ORDERS_PER_USER
    mapping(uint256 => mapping(address => uint256)) public userOrderCount;
    // Total active resting orders per market — used to detect activity for cancel restriction
    mapping(uint256 => uint256) public marketOrderCount;

    // Emergency pause — halts new trades and market creation; exits (cancel, redeem) remain open
    bool public paused;
    uint256 public pausedAt;

    // Creator fees accrued per market — claimable only after finalization
    mapping(uint256 => uint256) public creatorAccruedFees;

    // ── Reentrancy ──
    uint256 private _locked = 1;
    modifier nonReentrant() { require(_locked == 1, "Reentrant"); _locked = 2; _; _locked = 1; }

    // ── Emergency pause ──
    modifier whenNotPaused() {
        require(!paused || block.timestamp >= pausedAt + MAX_PAUSE_DURATION, "Contract paused");
        _;
    }
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ──────────────────────────── Events ───────────────────────────────
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question, string[] options, Category category, string resolutionCriteria, uint256 bettingDeadline, uint256 resolutionDeadline, bool isAdminMarket);
    event MarketImported(uint256 indexed marketId, address indexed creator, string pmConditionId);
    event SharesBoughtAMM(uint256 indexed marketId, address indexed buyer, uint256 optionIndex, uint256 shares, uint256 usdmSpent, uint256 newPrice);
    event SharesSoldToAMM(uint256 indexed marketId, address indexed seller, uint256 optionIndex, uint256 shares, uint256 usdmReceived, uint256 newPrice);
    event OrderPlaced(uint256 indexed orderId, uint256 indexed marketId, address indexed maker, OrderSide side, uint256 optionIndex, uint256 quantity, uint256 pricePerShare);
    event OrderFilled(uint256 indexed bidOrderId, uint256 indexed askOrderId, uint256 sharesFilled, uint256 usdmTransferred);
    event OrderCancelled(uint256 indexed orderId);
    event MarketResolved(uint256 indexed marketId, uint256 winningOption, uint256 resolvedAt);
    event MarketDisputed(uint256 indexed marketId, address indexed disputer, uint256 proposedOption);
    event DisputeSettled(uint256 indexed marketId, bool creatorWasRight, uint256 finalWinningOption);
    event MarketFinalized(uint256 indexed marketId, uint256 winningOption, uint256 poolBalance);
    event DisputeRewardAccrued(uint256 indexed marketId, address indexed disputer, uint256 indexed month, uint256 amount);
    event MonthlyDisputeRewardsDistributed(uint256 indexed month, uint256 pool, uint256 disputerCount);
    event WinningsRedeemed(uint256 indexed marketId, address indexed holder, uint256 shares, uint256 payout);
    event RefundClaimed(uint256 indexed marketId, address indexed holder, uint256 shares, uint256 refund);
    event BettingClosed(uint256 indexed marketId);
    event MarketCancelled(uint256 indexed marketId);
    event MarketSlashed(uint256 indexed marketId, address indexed creator, string reason);
    event CreatorFeesClaimed(uint256 indexed marketId, address indexed creator, uint256 amount);
    event CreatorFeesSlashed(uint256 indexed marketId, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event TreasuryWithdrawalRequested(address indexed to, uint256 amount, uint256 readyAt);
    event TreasuryWithdrawalCancelled(uint256 amount);
    event ResolverPoolUpdated(address indexed newAddress);
    event ResolverPoolChangeRequested(address indexed newAddress, uint256 readyAt);
    event ResolverPoolChangeCancelled(address indexed cancelledAddress);
    event DisputeResolverUpdated(address indexed newResolver);
    event ResolutionEvidence(uint256 indexed marketId, address indexed submitter, bytes32 evidenceHash);
    event FeeCollected(uint256 indexed marketId, address indexed creator, uint256 creatorCut, uint256 treasuryCut, uint256 resolverCut);
    event WalletWhitelisted(address indexed wallet);
    event WalletRemovedFromWhitelist(address indexed wallet);
    event AddressBanned(address indexed account);
    event AddressUnbanned(address indexed account);
    event MarketCreatorAdded(address indexed account);
    event MarketCreatorRemoved(address indexed account);
    event AdminOrderCancelled(uint256 indexed orderId, address indexed maker);
    event InviteCodeCreated(bytes32 indexed codeHash);
    event LosingSharesBurned(uint256 indexed marketId, uint256 totalBurned);
    /// @dev Emitted when _cancelAllOrders skips a transfer due to REX4 budget. Maker must call reclaimCancelledOrder.
    event OrderEscrowDeferred(uint256 indexed orderId);
    /// @dev Community upvote — one vote per address per market, no USDm required.
    event MarketUpvoted(uint256 indexed marketId, address indexed voter, uint256 newCount);

    // ──────────────────────────── Modifiers ────────────────────────────
    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyDisputeResolver() { require(msg.sender == disputeResolver, "Not dispute resolver"); _; }
    modifier onlyMarketCreator() {
        require(marketCreatorWhitelisted[msg.sender] || msg.sender == admin, "Not a market creator");
        _;
    }
    modifier onlyWhitelisted() {
        require(!banned[msg.sender], "Banned");
        if (whitelistEnabled) {
            require(whitelisted[msg.sender] || msg.sender == admin, "Not whitelisted");
        }
        _;
    }

    // ──────────────────────────── Constructor ──────────────────────────
    constructor(address _usdm) ERC1155("") {
        require(IERC20Metadata(_usdm).decimals() == 18, "USDM must be 18 decimals"); // EXT-04
        admin            = msg.sender;
        disputeResolver  = msg.sender; // must be updated to separate multisig before mainnet
        usdm             = IERC20(_usdm);
        resolverPoolAddress = msg.sender;
        whitelistEnabled    = true;
        whitelisted[msg.sender] = true;
        whitelistedCount = 1;
    }

    /// @dev EXT-01: balance-delta pattern for inbound USDM transfers.
    ///      Reverts if the token deducted a fee, ensuring internal accounting matches reality.
    function _receiveUSDM(address _from, uint256 _amount) internal {
        uint256 before = usdm.balanceOf(address(this));
        usdm.safeTransferFrom(_from, address(this), _amount);
        require(usdm.balanceOf(address(this)) - before == _amount, "Fee-on-transfer not supported");
    }

    // ══════════════════════════════════════════════════════════════════
    //                         WHITELIST
    // ══════════════════════════════════════════════════════════════════

    function addToWhitelist(address _wallet) external onlyAdmin {
        require(!banned[_wallet], "Address is banned");
        require(!whitelisted[_wallet], "Already whitelisted");
        whitelisted[_wallet] = true;
        whitelistedCount++;
        emit WalletWhitelisted(_wallet);
    }

    function batchWhitelist(address[] calldata _wallets) external onlyAdmin {
        for (uint256 i = 0; i < _wallets.length; i++) {
            if (!whitelisted[_wallets[i]] && !banned[_wallets[i]]) {
                whitelisted[_wallets[i]] = true;
                whitelistedCount++;
                emit WalletWhitelisted(_wallets[i]);
            }
        }
    }

    function removeFromWhitelist(address _wallet) external onlyAdmin {
        require(whitelisted[_wallet], "Not whitelisted");
        whitelisted[_wallet] = false;
        whitelistedCount--;
        emit WalletRemovedFromWhitelist(_wallet);
    }

    function addMarketCreator(address _account) external onlyAdmin {
        require(!banned[_account], "Address is banned");
        require(!marketCreatorWhitelisted[_account], "Already a market creator");
        marketCreatorWhitelisted[_account] = true;
        emit MarketCreatorAdded(_account);
    }

    function removeMarketCreator(address _account) external onlyAdmin {
        require(marketCreatorWhitelisted[_account], "Not a market creator");
        marketCreatorWhitelisted[_account] = false;
        emit MarketCreatorRemoved(_account);
    }

    function batchAddMarketCreators(address[] calldata _accounts) external onlyAdmin {
        for (uint256 i = 0; i < _accounts.length; i++) {
            if (!marketCreatorWhitelisted[_accounts[i]] && !banned[_accounts[i]]) {
                marketCreatorWhitelisted[_accounts[i]] = true;
                emit MarketCreatorAdded(_accounts[i]);
            }
        }
    }

    /// @notice Ban an address: removes from whitelist and blocks all future trading.
    ///         Cannot be re-whitelisted while banned. Use adminCancelOrders to refund open orders.
    function banAddress(address _account) external onlyAdmin {
        require(!banned[_account], "Already banned");
        banned[_account] = true;
        if (whitelisted[_account]) {
            whitelisted[_account] = false;
            whitelistedCount--;
            emit WalletRemovedFromWhitelist(_account);
        }
        if (marketCreatorWhitelisted[_account]) {
            marketCreatorWhitelisted[_account] = false;
            emit MarketCreatorRemoved(_account);
        }
        emit AddressBanned(_account);
    }

    function unbanAddress(address _account) external onlyAdmin {
        require(banned[_account], "Not banned");
        banned[_account] = false;
        emit AddressUnbanned(_account);
    }

    /// @notice Cancel a list of orders by ID and return escrowed funds to their makers.
    ///         Intended for emergency use (griefing, banned address cleanup).
    ///         Order IDs are found off-chain via the indexer filtered by maker address.
    function adminCancelOrders(uint256[] calldata _orderIds) external onlyAdmin nonReentrant {
        for (uint256 i = 0; i < _orderIds.length; i++) {
            Order storage o = orders[_orderIds[i]];
            if (!o.active) continue;

            // Effects
            o.active = false;
            if (userOrderCount[o.marketId][o.maker] > 0) userOrderCount[o.marketId][o.maker]--;
            uint256 qty      = o.quantityRemaining;
            uint256 escrowed = o.usdmEscrowed;
            o.quantityRemaining = 0;
            o.usdmEscrowed      = 0;
            emit AdminOrderCancelled(_orderIds[i], o.maker);

            // Interactions — return funds to maker
            if (o.side == OrderSide.BUY) {
                if (escrowed > 0) usdm.safeTransfer(o.maker, escrowed);
                _cleanBook(_bidBook[o.marketId][o.optionIndex]);
            } else {
                if (qty > 0) _safeTransferFrom(address(this), o.maker, _tokenId(o.marketId, o.optionIndex), qty, "");
                _cleanBook(_askBook[o.marketId][o.optionIndex]);
            }
        }
    }

    function setWhitelistEnabled(bool _enabled) external onlyAdmin {
        whitelistEnabled = _enabled;
    }

    function createInviteCode(bytes32 _codeHash) external onlyAdmin {
        inviteCodeValid[_codeHash] = true;
        emit InviteCodeCreated(_codeHash);
    }

    function redeemInviteCode(string calldata _code) external nonReentrant {
        bytes32 codeHash = keccak256(abi.encodePacked(_code));
        require(inviteCodeValid[codeHash], "Invalid code");
        require(!inviteCodeUsed[codeHash], "Code used");
        require(!whitelisted[msg.sender], "Already whitelisted");
        inviteCodeUsed[codeHash] = true;
        whitelisted[msg.sender] = true;
        whitelistedCount++;
        emit WalletWhitelisted(msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       MARKET CREATION
    // ══════════════════════════════════════════════════════════════════

    function createMarket(
        string calldata   _question,
        string[] calldata _options,
        Category          _category,
        string calldata   _resolutionCriteria,
        string calldata   _imageUrl,
        uint256           _bettingDeadline,
        uint256           _resolutionDeadline
    ) external onlyWhitelisted onlyMarketCreator whenNotPaused returns (uint256 marketId) {
        require(_options.length >= MIN_OPTIONS && _options.length <= MAX_OPTIONS, "2-4 options");
        require(_bettingDeadline >= block.timestamp + MIN_BETTING_WINDOW, "Betting window too short");
        require(_resolutionDeadline > _bettingDeadline, "Resolution after betting");
        require(bytes(_question).length > 0 && bytes(_question).length <= 300, "Question 1-300 chars");
        require(bytes(_resolutionCriteria).length > 0, "Criteria required");

        uint256 n       = _options.length;
        uint256 subsidy = uint256(unwrap(mul(wrap(SafeCast.toInt256(LMSR_B)), ln(wrap(SafeCast.toInt256(n) * 1e18)))));

        _receiveUSDM(msg.sender, CREATOR_COLLATERAL + subsidy);

        marketId = nextMarketId++;
        Market storage m = _markets[marketId];
        m.creator            = msg.sender;
        m.question           = _question;
        m.category           = _category;
        m.resolutionCriteria = _resolutionCriteria;
        m.imageUrl           = _imageUrl;
        m.bettingDeadline    = _bettingDeadline;
        m.resolutionDeadline = _resolutionDeadline;
        m.createdAt          = block.timestamp;
        m.status             = MarketStatus.Active;
        m.winningOption      = type(uint256).max; // INV-06: sentinel — not yet resolved
        m.b                  = LMSR_B;
        m.subsidyDeposited   = subsidy;

        for (uint256 i = 0; i < n; i++) {
            require(bytes(_options[i]).length > 0 && bytes(_options[i]).length <= 100, "Option 1-100 chars");
            m.options.push(_options[i]);
            m.quantities.push(0);
        }

        emit MarketCreated(marketId, msg.sender, _question, _options, _category, _resolutionCriteria, _bettingDeadline, _resolutionDeadline, false);
    }

    function createAdminMarket(
        string calldata   _question,
        string[] calldata _options,
        Category          _category,
        string calldata   _resolutionCriteria,
        string calldata   _imageUrl,
        uint256           _bettingDeadline,
        uint256           _resolutionDeadline
    ) external onlyAdmin whenNotPaused returns (uint256 marketId) {
        require(_options.length >= MIN_OPTIONS && _options.length <= MAX_OPTIONS, "2-4 options");
        require(_bettingDeadline >= block.timestamp + MIN_BETTING_WINDOW, "Betting window too short");
        require(_resolutionDeadline > _bettingDeadline, "Resolution after betting");

        uint256 n       = _options.length;
        uint256 subsidy = uint256(unwrap(mul(wrap(SafeCast.toInt256(LMSR_B)), ln(wrap(SafeCast.toInt256(n) * 1e18)))));
        _receiveUSDM(msg.sender, subsidy);

        marketId = nextMarketId++;
        Market storage m = _markets[marketId];
        m.creator                   = msg.sender;
        m.question                  = _question;
        m.category                  = _category;
        m.resolutionCriteria        = _resolutionCriteria;
        m.imageUrl                  = _imageUrl;
        m.bettingDeadline           = _bettingDeadline;
        m.resolutionDeadline        = _resolutionDeadline;
        m.createdAt                 = block.timestamp;
        m.status                    = MarketStatus.Active;
        m.winningOption             = type(uint256).max; // INV-06: sentinel — not yet resolved
        m.isAdminMarket             = true;
        m.creatorCollateralReturned = true; // no collateral locked for admin markets
        m.b                         = LMSR_B;
        m.subsidyDeposited          = subsidy;

        for (uint256 i = 0; i < n; i++) {
            m.options.push(_options[i]);
            m.quantities.push(0);
        }

        emit MarketCreated(marketId, msg.sender, _question, _options, _category, _resolutionCriteria, _bettingDeadline, _resolutionDeadline, true);
    }

    /// @notice Create a market imported from Polymarket.
    ///         Costs IMPORT_FEE (10 USDm, sent to treasury) + LMSR subsidy. No collateral locked.
    ///         Creator earns 0.5% fees (vs 1% for regular); the saved 0.5% goes to treasury.
    ///         Each pm_condition_id can only be imported once.
    ///         AC-08: resolution is admin-only and centralized — pmConditionId is not verified on-chain
    ///         against Polymarket/UMA. A decentralized oracle integration is planned post-TGE.
    function createImportedMarket(
        string calldata   _question,
        string[] calldata _options,
        Category          _category,
        string calldata   _resolutionCriteria,
        string calldata   _imageUrl,
        uint256           _bettingDeadline,
        uint256           _resolutionDeadline,
        string calldata   _pmConditionId
    ) external onlyWhitelisted onlyMarketCreator whenNotPaused returns (uint256 marketId) {
        require(_options.length >= MIN_OPTIONS && _options.length <= MAX_OPTIONS, "2-4 options");
        require(_bettingDeadline >= block.timestamp + MIN_BETTING_WINDOW, "Betting window too short");
        require(_resolutionDeadline > _bettingDeadline, "Resolution after betting");
        require(bytes(_question).length > 0 && bytes(_question).length <= 300, "Question 1-300 chars");
        require(bytes(_resolutionCriteria).length > 0, "Criteria required");
        _validateConditionId(_pmConditionId); // Q7: 66-char 0x-prefixed lowercase hex, prevents case-aliased duplicates

        bytes32 conditionKey = keccak256(abi.encodePacked(_pmConditionId));
        require(!pmConditionImported[conditionKey], "Already imported");
        pmConditionImported[conditionKey] = true;

        uint256 n       = _options.length;
        uint256 subsidy = uint256(unwrap(mul(wrap(SafeCast.toInt256(LMSR_B)), ln(wrap(SafeCast.toInt256(n) * 1e18)))));

        // Import fee goes immediately to treasury; only subsidy is locked in the LMSR pool.
        _receiveUSDM(msg.sender, IMPORT_FEE + subsidy);
        treasuryBalance += IMPORT_FEE;

        marketId = nextMarketId++;
        Market storage m = _markets[marketId];
        m.creator                   = msg.sender;
        m.question           = _question;
        m.category           = _category;
        m.resolutionCriteria = _resolutionCriteria;
        m.imageUrl           = _imageUrl;
        m.bettingDeadline    = _bettingDeadline;
        m.resolutionDeadline = _resolutionDeadline;
        m.createdAt          = block.timestamp;
        m.status                    = MarketStatus.Active;
        m.winningOption             = type(uint256).max; // INV-06: sentinel — not yet resolved
        m.isImportedMarket          = true;
        m.creatorCollateralReturned = true;  // no collateral: fee was paid to treasury at creation
        m.pmConditionId             = _pmConditionId;
        m.b                         = LMSR_B;
        m.subsidyDeposited          = subsidy;

        for (uint256 i = 0; i < n; i++) {
            require(bytes(_options[i]).length > 0 && bytes(_options[i]).length <= 100, "Option 1-100 chars");
            m.options.push(_options[i]);
            m.quantities.push(0);
        }

        emit MarketCreated(marketId, msg.sender, _question, _options, _category, _resolutionCriteria, _bettingDeadline, _resolutionDeadline, false);
        emit MarketImported(marketId, msg.sender, _pmConditionId);
    }

    // ══════════════════════════════════════════════════════════════════
    //                         LMSR AMM PRICING
    // ══════════════════════════════════════════════════════════════════

    /// @notice LMSR implied probability of option _opt (1e18 = 100%)
    /// @dev p_i = exp(q_i/b) / Σ exp(q_j/b)
    ///      ECON-06: NOT safe as an external price oracle — manipulable via large AMM trades.
    ///      Use a TWAP wrapper if you need this as an oracle feed.
    function getPrice(uint256 _marketId, uint256 _opt) public view returns (uint256) {
        Market storage m = _markets[_marketId];
        require(_opt < m.options.length, "Invalid option");
        int256 numArg = SafeCast.toInt256(m.quantities[_opt] * 1e18 / m.b);
        require(numArg <= EXP_MAX_ARG, "LMSR: exp overflow");
        SD59x18 num   = exp(wrap(numArg));
        SD59x18 denom = wrap(0);
        for (uint256 i = 0; i < m.quantities.length; i++) {
            int256 arg = SafeCast.toInt256(m.quantities[i] * 1e18 / m.b);
            require(arg <= EXP_MAX_ARG, "LMSR: exp overflow");
            denom = add(denom, exp(wrap(arg)));
        }
        return uint256(unwrap(div(num, denom)));
    }

    /// @notice Shares out for _usdmNet (post-fee) via binary search on LMSR cost function.
    ///         Tolerance: 1e15 shares. Safe cap: ~26,600 USDm per tx (exp overflow bound).
    function quoteBuy(uint256 _marketId, uint256 _opt, uint256 _usdmNet) public view returns (uint256 sharesOut) {
        Market storage m = _markets[_marketId];
        require(_opt < m.options.length, "Invalid option");
        if (_usdmNet == 0) return 0;

        uint256 b_ = m.b;
        uint256 n  = m.quantities.length;

        uint256 maxQ = 26000e18;
        uint256 hi   = maxQ > m.quantities[_opt] ? maxQ - m.quantities[_opt] : 0;
        require(hi > 0, "Market at capacity");

        uint256[] memory q = new uint256[](n);
        for (uint256 i = 0; i < n; i++) q[i] = m.quantities[i];

        uint256 costBefore = _lmsrCost(q, b_);

        q[_opt] = m.quantities[_opt] + hi;
        require(_lmsrCost(q, b_) - costBefore >= _usdmNet, "Amount exceeds market capacity");

        uint256 lo = 0;
        while (hi - lo > 1e12) { // MATH-05: tighter tolerance (was 1e15, ~0.001 share lost per trade)
            uint256 mid = (lo + hi) / 2;
            q[_opt] = m.quantities[_opt] + mid;
            if (_lmsrCost(q, b_) - costBefore < _usdmNet) { lo = mid; } else { hi = mid; }
        }
        sharesOut = lo;
    }

    /// @notice USDm gross output (pre-fee) for selling _shares back to AMM.
    function quoteSell(uint256 _marketId, uint256 _opt, uint256 _shares) public view returns (uint256 usdmOut) {
        Market storage m = _markets[_marketId];
        require(_opt < m.options.length, "Invalid option");
        require(_shares <= m.quantities[_opt], "Insufficient pool shares");

        uint256 n = m.quantities.length;
        uint256[] memory q = new uint256[](n);
        for (uint256 i = 0; i < n; i++) q[i] = m.quantities[i];

        uint256 costBefore = _lmsrCost(q, m.b);
        q[_opt] -= _shares;
        uint256 costAfter = _lmsrCost(q, m.b);
        usdmOut = costBefore >= costAfter ? costBefore - costAfter : 0;
    }

    // ══════════════════════════════════════════════════════════════════
    //                      CLOB — PLACE ORDER
    // ══════════════════════════════════════════════════════════════════

    /// @notice Place a BUY or SELL limit order. Immediate matching attempted (price-time priority).
    ///         BUY:  USDm escrowed upfront. CLOB asks at or below _price filled first.
    ///               Remaining budget routed to LMSR AMM. Unspent dust refunded.
    ///         SELL: Shares escrowed upfront. CLOB bids at or above _price filled first.
    ///               Unmatched remainder rests as a limit order in the ask book.
    /// @param _marketId Market to trade in
    /// @param _opt      Option index
    /// @param _side     BUY or SELL
    /// @param _quantity Shares to buy/sell (1e18 = 1 share)
    /// @param _price    Limit price per share in USDm (18 dec). Must be 0 < price < 1e18
    /// @param _minFill  Slippage guard — revert if total shares filled < _minFill (use 0 to disable)
    /// @return orderId     ID of the resting order created (0 if fully filled)
    /// @return totalFilled Total shares filled immediately (CLOB + AMM for BUY)
    function placeOrder(
        uint256   _marketId,
        uint256   _opt,
        OrderSide _side,
        uint256   _quantity,
        uint256   _price,
        uint256   _minFill
    ) external onlyWhitelisted nonReentrant whenNotPaused returns (uint256 orderId, uint256 totalFilled) {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Active,  "Not active");
        require(block.timestamp < m.bettingDeadline, "Betting closed");
        require(_opt < m.options.length,          "Invalid option");
        require(_quantity >= MIN_TRADE,            "Too few shares");
        require(_price > 0 && _price < SHARE_UNIT, "Price must be 0 < p < 1");
        require(msg.sender != m.creator,           "Creator cannot trade own market"); // ECON-07
        require((_quantity * _price) / SHARE_UNIT >= MIN_ORDER_VALUE, "Order below 1 USDm minimum"); // ATCK-06
        if (_side == OrderSide.BUY) {
            require(_minFill >= MIN_TRADE, "BUY requires minFill >= MIN_TRADE"); // ATCK-03
        }
        if (!hasParticipated[_marketId][msg.sender]) hasParticipated[_marketId][msg.sender] = true;

        uint256 sharesRemaining;

        if (_side == OrderSide.BUY) {
            // ── BUY: escrow max USDm needed ──
            uint256 maxUsdm = (_quantity * _price) / SHARE_UNIT;
            require(maxUsdm > 0, "Zero escrow");
            _receiveUSDM(msg.sender, maxUsdm);

            uint256 usdmRemaining   = maxUsdm;
            sharesRemaining         = _quantity;

            // Phase 1: fill ask orders (ascending price, FIFO within price)
            uint256[] storage asks = _askBook[_marketId][_opt];
            for (uint256 i = 0; i < asks.length && sharesRemaining >= MIN_TRADE && usdmRemaining > 0; i++) {
                // REX4-01: each iteration makes 2 external calls; bail if budget is too thin.
                // gasleft() reflects remaining REX4 frame budget on MegaETH.
                if (gasleft() < REX4_MIN_GAS_PER_ITER) break;
                Order storage ask = orders[asks[i]];
                if (!ask.active || ask.quantityRemaining == 0 || ask.pricePerShare > _price) continue;

                uint256 fill = sharesRemaining < ask.quantityRemaining ? sharesRemaining : ask.quantityRemaining;
                uint256 cost = (fill * ask.pricePerShare) / SHARE_UNIT;
                if (cost == 0 || cost > usdmRemaining) continue;

                // Effects
                uint256 sellerGets = _collectFees(m, _marketId, cost);
                ask.quantityRemaining -= fill;
                if (ask.quantityRemaining == 0) {
                    ask.active = false;
                    if (userOrderCount[_marketId][ask.maker] > 0) userOrderCount[_marketId][ask.maker]--;
                    if (marketOrderCount[_marketId] > 0) marketOrderCount[_marketId]--;
                }
                sharesRemaining -= fill;
                usdmRemaining   -= cost;
                totalFilled     += fill;
                m.totalVolume   += cost;

                // Interactions (seller receives USDm; buyer receives shares from escrow)
                usdm.safeTransfer(ask.maker, sellerGets);
                _safeTransferFrom(address(this), msg.sender, _tokenId(_marketId, _opt), fill, "");
                emit OrderFilled(type(uint256).max, asks[i], fill, cost);
            }
            _cleanBook(asks);

            // Phase 2: route remaining USDm to LMSR AMM
            if (usdmRemaining >= MIN_TRADE) {
                uint256 netUsdm   = _collectFees(m, _marketId, usdmRemaining);
                uint256 ammShares = quoteBuy(_marketId, _opt, netUsdm);
                if (ammShares >= MIN_TRADE) {
                    m.quantities[_opt]            += ammShares;
                    _mint(msg.sender, _tokenId(_marketId, _opt), ammShares, "");
                    optionSupply[_marketId][_opt]  += ammShares;
                    m.poolBalance                  += netUsdm;
                    m.totalVolume                  += usdmRemaining;
                    totalFilled                    += ammShares;
                    // ECON-12: budget fully spent on AMM — no USDm left to back a BUY rest order
                    sharesRemaining = 0;
                    usdmRemaining   = 0;
                    emit SharesBoughtAMM(_marketId, msg.sender, _opt, ammShares, netUsdm, getPrice(_marketId, _opt));
                }
            }

            // Refund any unspent dust (occurs when AMM capacity is hit)
            if (usdmRemaining > 0) {
                usdm.safeTransfer(msg.sender, usdmRemaining);
                sharesRemaining = 0; // nothing left to rest
            }

        } else {
            // ── SELL: escrow all shares upfront ──
            require(balanceOf(msg.sender, _tokenId(_marketId, _opt)) >= _quantity, "Insufficient shares");
            _safeTransferFrom(msg.sender, address(this), _tokenId(_marketId, _opt), _quantity, "");

            sharesRemaining = _quantity;

            // Fill bid orders (descending price, FIFO within price)
            uint256[] storage bids = _bidBook[_marketId][_opt];
            for (uint256 i = 0; i < bids.length && sharesRemaining >= MIN_TRADE; i++) {
                // REX4-01: each iteration makes 2 external calls; bail if budget is too thin.
                if (gasleft() < REX4_MIN_GAS_PER_ITER) break;
                Order storage bid = orders[bids[i]];
                if (!bid.active || bid.quantityRemaining == 0 || bid.pricePerShare < _price) continue;

                uint256 fill     = sharesRemaining < bid.quantityRemaining ? sharesRemaining : bid.quantityRemaining;
                uint256 proceeds = (fill * bid.pricePerShare) / SHARE_UNIT;
                if (proceeds == 0 || proceeds > bid.usdmEscrowed) continue;

                // Effects
                uint256 sellerGets = _collectFees(m, _marketId, proceeds);
                bid.quantityRemaining -= fill;
                bid.usdmEscrowed      -= proceeds;
                if (bid.quantityRemaining == 0) {
                    bid.active = false;
                    if (userOrderCount[_marketId][bid.maker] > 0) userOrderCount[_marketId][bid.maker]--;
                    if (marketOrderCount[_marketId] > 0) marketOrderCount[_marketId]--;
                }
                sharesRemaining -= fill;
                totalFilled     += fill;
                m.totalVolume   += proceeds;

                // Interactions (seller receives USDm; buyer receives shares from escrow)
                usdm.safeTransfer(msg.sender, sellerGets);
                _safeTransferFrom(address(this), bid.maker, _tokenId(_marketId, _opt), fill, "");
                emit OrderFilled(bids[i], type(uint256).max, fill, proceeds);
            }
            _cleanBook(bids);
        }

        require(totalFilled >= _minFill, "Slippage: too few shares filled");

        // Rest any unfilled portion as a limit order
        if (sharesRemaining >= MIN_TRADE) {
            orderId = _restOrder(_marketId, _opt, _side, _price, sharesRemaining, m);
        } else if (_side == OrderSide.SELL && sharesRemaining > 0) {
            // Dust too small to rest — return escrowed shares
            _safeTransferFrom(address(this), msg.sender, _tokenId(_marketId, _opt), sharesRemaining, "");
        }
    }

    /// @dev Create a resting CLOB order after immediate matching is exhausted.
    function _restOrder(
        uint256   _marketId,
        uint256   _opt,
        OrderSide _side,
        uint256   _price,
        uint256   _qty,
        Market storage m
    ) internal returns (uint256 orderId) {
        require(userOrderCount[_marketId][msg.sender] < MAX_ORDERS_PER_USER, "Too many active orders");
        userOrderCount[_marketId][msg.sender]++;
        marketOrderCount[_marketId]++;
        orderId = nextOrderId++;

        if (_side == OrderSide.BUY) {
            uint256[] storage bids = _bidBook[_marketId][_opt];
            _cleanBook(bids); // INV-08: clean before length check to reclaim inactive slots
            require(bids.length < MAX_ORDERS_PER_BOOK, "Bid book full");
            uint256 usdmHeld = (_qty * _price) / SHARE_UNIT;
            orders[orderId] = Order({
                maker:             msg.sender,
                marketId:          _marketId,
                optionIndex:       _opt,
                side:              OrderSide.BUY,
                pricePerShare:     _price,
                quantityRemaining: _qty,
                usdmEscrowed:      usdmHeld,
                active:            true,
                placedAt:          block.timestamp
            });
            _insertSorted(bids, orderId, _price, false); // descending

        } else {
            uint256[] storage asks = _askBook[_marketId][_opt];
            _cleanBook(asks); // INV-08: clean before length check to reclaim inactive slots
            require(asks.length < MAX_ORDERS_PER_BOOK, "Ask book full");
            // Shares already escrowed in contract from placeOrder
            orders[orderId] = Order({
                maker:             msg.sender,
                marketId:          _marketId,
                optionIndex:       _opt,
                side:              OrderSide.SELL,
                pricePerShare:     _price,
                quantityRemaining: _qty,
                usdmEscrowed:      0,
                active:            true,
                placedAt:          block.timestamp
            });
            _insertSorted(asks, orderId, _price, true); // ascending
        }

        emit OrderPlaced(orderId, _marketId, msg.sender, _side, _opt, _qty, _price);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      CLOB — CANCEL ORDER
    // ══════════════════════════════════════════════════════════════════

    /// @notice Cancel a resting order. Escrowed USDm or shares returned immediately.
    ///         Dead entry removed from book on cancellation (fix F-DS-M02).
    function cancelOrder(uint256 _orderId) external nonReentrant {
        Order storage o = orders[_orderId];
        require(o.maker == msg.sender, "Not your order");
        require(o.active, "Already cancelled");

        // Effects first (CEI)
        o.active = false;
        if (userOrderCount[o.marketId][msg.sender] > 0) userOrderCount[o.marketId][msg.sender]--;
        if (marketOrderCount[o.marketId] > 0) marketOrderCount[o.marketId]--;
        uint256 qty      = o.quantityRemaining;
        uint256 escrowed = o.usdmEscrowed;
        o.quantityRemaining = 0;
        o.usdmEscrowed      = 0;

        if (o.side == OrderSide.BUY) {
            // Interactions: return escrowed USDm
            if (escrowed > 0) usdm.safeTransfer(msg.sender, escrowed);
            _cleanBook(_bidBook[o.marketId][o.optionIndex]); // F-DS-M02 fix
        } else {
            // Interactions: return escrowed shares
            if (qty > 0) _safeTransferFrom(address(this), msg.sender, _tokenId(o.marketId, o.optionIndex), qty, "");
            _cleanBook(_askBook[o.marketId][o.optionIndex]); // F-DS-M02 fix
        }

        emit OrderCancelled(_orderId);
    }

    // ══════════════════════════════════════════════════════════════════
    //                       SELL TO AMM (INSTANT)
    // ══════════════════════════════════════════════════════════════════

    /// @notice Sell shares instantly to the LMSR AMM at current AMM price.
    ///         No limit order — immediate execution at whatever the AMM offers.
    function sellToAMM(
        uint256 _marketId,
        uint256 _opt,
        uint256 _shares,
        uint256 _minUsdm
    ) external onlyWhitelisted nonReentrant whenNotPaused returns (uint256 netUsdm) {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Active, "Not active");
        require(block.timestamp < m.bettingDeadline, "Betting closed");
        require(_opt < m.options.length, "Invalid option");
        require(_shares >= MIN_TRADE, "Too few shares");
        require(_shares >= MIN_ORDER_VALUE, "Order below 1 USDm minimum"); // ATCK-06: 1 share min (1 USDm payout)
        require(msg.sender != m.creator, "Creator cannot trade own market"); // ECON-07
        require(_minUsdm > 0, "Slippage: _minUsdm required");
        require(balanceOf(msg.sender, _tokenId(_marketId, _opt)) >= _shares, "Insufficient shares");
        if (!hasParticipated[_marketId][msg.sender]) hasParticipated[_marketId][msg.sender] = true;

        uint256 grossUsdm = quoteSell(_marketId, _opt, _shares);
        require(grossUsdm > 0, "Zero output");
        require(grossUsdm <= m.poolBalance, "Insufficient pool liquidity");

        // Effects
        m.quantities[_opt]           -= _shares;
        _burn(msg.sender, _tokenId(_marketId, _opt), _shares);
        optionSupply[_marketId][_opt] -= _shares;
        m.poolBalance                 -= grossUsdm;
        m.totalVolume                 += grossUsdm;
        netUsdm = _collectFees(m, _marketId, grossUsdm);
        require(netUsdm >= _minUsdm, "Slippage: too little USDm");

        // Interaction
        usdm.safeTransfer(msg.sender, netUsdm);
        emit SharesSoldToAMM(_marketId, msg.sender, _opt, _shares, netUsdm, getPrice(_marketId, _opt));
    }

    // ══════════════════════════════════════════════════════════════════
    //                        RESOLUTION
    // ══════════════════════════════════════════════════════════════════

    /// @notice Resolves the market after betting deadline.
    ///         Imported markets: admin only (resolution follows Polymarket/UMA oracle outcome).
    ///         Regular markets: callable by the creator or admin.
    ///         All resting CLOB orders are cancelled and escrowed funds returned.
    function resolveMarket(uint256 _marketId, uint256 _winningOption, bytes32 _evidenceHash) external nonReentrant {
        Market storage m = _markets[_marketId];
        if (m.isImportedMarket) {
            require(msg.sender == admin, "Imported market: admin only");
        } else {
            require(msg.sender == m.creator, "Only creator");
        }
        require(m.status == MarketStatus.Active || m.status == MarketStatus.BettingClosed, "Cannot resolve");
        require(block.timestamp >= m.bettingDeadline, "Betting not closed");
        require(block.timestamp <= m.resolutionDeadline, "Deadline passed");
        require(_winningOption < m.options.length, "Invalid option");
        require(_evidenceHash != bytes32(0), "Evidence required");

        m.status        = MarketStatus.Resolved;
        m.winningOption = _winningOption;
        m.resolvedAt    = block.timestamp;

        emit ResolutionEvidence(_marketId, msg.sender, _evidenceHash);
        _cancelAllOrders(_marketId);
        emit MarketResolved(_marketId, _winningOption, block.timestamp);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          DISPUTE
    // ══════════════════════════════════════════════════════════════════

    function disputeMarket(uint256 _marketId, uint256 _proposedOption) external onlyWhitelisted nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Resolved, "Not resolved");
        require(block.timestamp < m.resolvedAt + DISPUTE_WINDOW, "Window closed");
        require(msg.sender != m.creator, "Creator cannot dispute");
        require(_proposedOption < m.options.length, "Invalid option");
        require(_proposedOption != m.winningOption, "Same as current");
        require(m.disputer == address(0), "Already disputed");
        // Only market participants or admin can dispute — prevents random addresses from
        // locking up markets without having skin in the game
        require(hasParticipated[_marketId][msg.sender] || msg.sender == admin, "Must be market participant");

        bool isAdmin = msg.sender == admin;
        if (!isAdmin) _receiveUSDM(msg.sender, DISPUTE_COLLATERAL);
        m.status                   = MarketStatus.Disputed;
        m.disputer                 = msg.sender;
        m.disputeOption            = _proposedOption;
        m.disputerPaidCollateral   = !isAdmin;

        emit MarketDisputed(_marketId, msg.sender, _proposedOption);
    }

    function settleDispute(
        uint256 _marketId,
        bool    _creatorWasRight,
        uint256 _finalOption,
        bytes32 _evidenceHash
    ) external onlyDisputeResolver nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Disputed, "Not disputed");
        require(_finalOption < m.options.length, "Invalid option");
        require(_evidenceHash != bytes32(0), "Evidence required");

        // Note: admin markets have no creator collateral (creatorCollateralReturned = true at creation).

        emit ResolutionEvidence(_marketId, msg.sender, _evidenceHash);

        // Effects before interactions (CEI fix — EXEC-04)
        m.status      = MarketStatus.Finalized;
        m.finalizedAt = block.timestamp;

        if (_creatorWasRight) {
            // Disputer was wrong.
            // If they paid collateral (regular user), it goes to treasury.
            // If admin disputed (no collateral paid), treasury gets nothing from disputer.
            if (m.disputerPaidCollateral) treasuryBalance += DISPUTE_COLLATERAL;
            emit DisputeSettled(_marketId, true, m.winningOption);
            emit MarketFinalized(_marketId, m.winningOption, m.poolBalance);
        } else {
            // Creator was wrong.
            // Creator loses 50 USDm collateral:
            //   Regular disputer: 25 USDm → treasury, 25 USDm → returned to disputer as reward.
            //   Admin disputer:   50 USDm → treasury (both halves, since no collateral was posted).
            // Plus all creator accrued fees are slashed to treasury.
            // 30% of net treasury gain routes to the monthly dispute lottery pool.
            m.winningOption             = _finalOption;
            m.creatorCollateralReturned = true;
            m.creatorFeePaid            = true;

            uint256 slashedFees = creatorAccruedFees[_marketId];
            if (slashedFees > 0) {
                creatorAccruedFees[_marketId] = 0;
                emit CreatorFeesSlashed(_marketId, slashedFees);
            }

            // baseGain: portion of creator collateral that actually reaches the treasury
            uint256 baseGain    = m.disputerPaidCollateral ? 25e18 : 50e18;
            uint256 treasuryGain = baseGain + slashedFees;
            uint256 lotteryShare = (treasuryGain * DISPUTE_REWARD_SHARE_BPS) / 10000;
            uint256 month        = block.timestamp / DISPUTE_MONTH_DURATION;

            monthlyDisputePool[month] += lotteryShare;
            _monthlyDisputers[month].push(m.disputer);
            treasuryBalance += treasuryGain - lotteryShare;

            emit DisputeRewardAccrued(_marketId, m.disputer, month, lotteryShare);
            emit DisputeSettled(_marketId, false, _finalOption);
            emit MarketFinalized(_marketId, _finalOption, m.poolBalance);

            // Interaction last: if disputer paid collateral, return it + 25 USDm reward.
            if (m.disputerPaidCollateral) {
                usdm.safeTransfer(m.disputer, DISPUTE_COLLATERAL + 25e18);
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════
    //                       FINALIZATION
    // ══════════════════════════════════════════════════════════════════

    /// @dev SEC-01: nonReentrant added; creatorCollateralReturned flag set BEFORE transfer (CEI).
    ///      ATCK-07: FINALIZE_BUFFER adds 1h margin against sequencer timestamp manipulation.
    function finalizeMarket(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Resolved, "Not resolved");
        require(block.timestamp >= m.resolvedAt + DISPUTE_WINDOW + FINALIZE_BUFFER, "Dispute window open");

        m.status      = MarketStatus.Finalized;
        m.finalizedAt = block.timestamp;

        if (!m.creatorCollateralReturned) {
            uint256 col = CREATOR_COLLATERAL;
            m.creatorCollateralReturned = true; // SEC-01: flag set before transfer (CEI)
            usdm.safeTransfer(m.creator, col);
        }

        emit MarketFinalized(_marketId, m.winningOption, m.poolBalance);
    }

    /// @notice Creator claims accrued trading fees. Only callable after finalization.
    /// @dev Fix R2-2: status must be Finalized (not Disputed), which implicitly blocks
    ///      any front-run attempt during the dispute resolution phase.
    function claimCreatorFees(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Finalized, "Not finalized"); // R2-2: Disputed blocked
        require(msg.sender == m.creator, "Not creator");
        require(!m.creatorFeePaid, "Already claimed");

        uint256 fees = creatorAccruedFees[_marketId];
        require(fees > 0, "No fees");

        m.creatorFeePaid              = true;
        creatorAccruedFees[_marketId] = 0;

        usdm.safeTransfer(m.creator, fees);
        emit CreatorFeesClaimed(_marketId, m.creator, fees);
    }

    // ══════════════════════════════════════════════════════════════════
    //                    REDEEM WINNINGS / REFUND
    // ══════════════════════════════════════════════════════════════════

    /// @notice Burn winning shares and receive 1 USDm per share (or pro-rata if pool deficit).
    ///         LMSR guarantees solvency for AMM-minted shares; pro-rata is a safety fallback (ECON-08).
    function redeemWinnings(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Finalized, "Not finalized");

        uint256 tokenId = _tokenId(_marketId, m.winningOption);
        uint256 shares  = balanceOf(msg.sender, tokenId);
        require(shares > 0, "No winning shares");

        // ECON-08: pro-rata fallback — should never trigger in normal operation (LMSR solvency proof),
        // but prevents permanent fund lock if an accounting bug causes a deficit.
        uint256 totalPool    = m.poolBalance + m.subsidyDeposited;
        uint256 totalWinning = optionSupply[_marketId][m.winningOption];
        uint256 payout = (totalPool >= totalWinning)
            ? shares                              // full 1 USDm per share (normal path)
            : (totalPool * shares) / totalWinning; // pro-rata if deficit

        // Deduct from poolBalance first, then subsidyDeposited
        if (payout <= m.poolBalance) {
            m.poolBalance -= payout;
        } else {
            uint256 fromSubsidy = payout - m.poolBalance;
            m.subsidyDeposited -= fromSubsidy;
            m.poolBalance       = 0;
        }

        _burn(msg.sender, tokenId, shares);
        optionSupply[_marketId][m.winningOption] -= shares;

        usdm.safeTransfer(msg.sender, payout);
        emit WinningsRedeemed(_marketId, msg.sender, shares, payout);
    }

    /// @notice Pro-rata refund from cancelled or slashed market.
    /// @dev Fix F-02: allTotal snapshot taken BEFORE burning to prevent over-extraction.
    ///      Fix GROK-M01: subsidyDeposited is included in the effective refund pool so the
    ///      creator's LMSR subsidy is not permanently stranded on cancel/slash.
    function claimCancelRefund(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Cancelled || m.status == MarketStatus.Slashed, "Not cancelled");

        // F-02: snapshot total supply BEFORE any burn
        uint256 nOpts    = m.options.length; // OPT-01: cache length
        uint256 allTotal = 0;
        for (uint256 i = 0; i < nOpts; i++) {
            allTotal += optionSupply[_marketId][i];
        }
        require(allTotal > 0, "No supply");

        uint256 userTotal = 0;
        for (uint256 i = 0; i < nOpts; i++) {
            uint256 tid = _tokenId(_marketId, i);
            uint256 bal = balanceOf(msg.sender, tid);
            if (bal > 0) {
                _burn(msg.sender, tid, bal);
                optionSupply[_marketId][i] -= bal;
                userTotal += bal;
            }
        }
        require(userTotal > 0, "Nothing to refund");

        // GROK-M01: effective pool = poolBalance + subsidyDeposited (subsidy was locked at creation;
        // it should be recoverable by share-holders on cancel, not permanently stranded in the contract)
        uint256 effectivePool = m.poolBalance + m.subsidyDeposited;
        // MATH-10: last claimer (userTotal == allTotal) gets the full remaining pool
        // to prevent integer-division dust being permanently stranded in the contract.
        uint256 refund = (userTotal == allTotal) ? effectivePool : (effectivePool * userTotal) / allTotal;

        // Deduct proportionally from poolBalance first, then subsidyDeposited
        if (refund <= m.poolBalance) {
            m.poolBalance -= refund;
        } else {
            uint256 fromSubsidy = refund - m.poolBalance;
            m.poolBalance = 0;
            m.subsidyDeposited -= fromSubsidy;
        }

        usdm.safeTransfer(msg.sender, refund);
        emit RefundClaimed(_marketId, msg.sender, userTotal, refund);
    }

    // ══════════════════════════════════════════════════════════════════
    //                  AUTO-BURN LOSING SHARES (KEEPER)
    // ══════════════════════════════════════════════════════════════════

    /// @notice Burn all losing shares held by _holders after finalization + BURN_DELAY (24h).
    ///         Called by admin keeper bot monitoring MarketFinalized events off-chain.
    ///         _holders list must be derived from on-chain Transfer events by the keeper.
    ///         Losing shares are worthless. This call cleans contract state permanently.
    /// @dev    Can only be called once per market (losingSharesBurned flag).
    ///         ERC-1155 has no enumerable holders — keeper supplies the list.
    function burnLosingShares(
        uint256          _marketId,
        address[] calldata _holders
    ) external onlyAdmin nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Finalized,                    "Not finalized");
        require(block.timestamp >= m.finalizedAt + BURN_DELAY,         "Burn delay not elapsed");
        require(!m.losingSharesBurned,                                  "Already burned");

        m.losingSharesBurned = true;
        uint256 totalBurned  = 0;
        uint256 nOpts        = m.options.length; // OPT-01: cache length

        for (uint256 opt = 0; opt < nOpts; opt++) {
            if (opt == m.winningOption) continue; // skip winning option

            uint256 tid = _tokenId(_marketId, opt);
            for (uint256 h = 0; h < _holders.length; h++) {
                // REX4-03: _burn triggers ERC-1155 callbacks; guard each iteration.
                // Keeper should re-submit with remaining holders if this breaks early.
                if (gasleft() < REX4_MIN_GAS_PER_ITER) break;
                uint256 bal = balanceOf(_holders[h], tid);
                if (bal > 0) {
                    _burn(_holders[h], tid, bal);
                    optionSupply[_marketId][opt] -= bal;
                    totalBurned += bal;
                }
            }
        }

        emit LosingSharesBurned(_marketId, totalBurned);
    }

    // ══════════════════════════════════════════════════════════════════
    //                      CANCEL & SLASH
    // ══════════════════════════════════════════════════════════════════

    function cancelMarket(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Active || m.status == MarketStatus.BettingClosed, "Cannot cancel");

        bool isTimeout  = block.timestamp > m.resolutionDeadline;
        bool hasActivity = m.totalVolume > 0 || marketOrderCount[_marketId] > 0;

        // If the market has any activity (trades or open orders), voluntary cancel is forbidden —
        // the creator must resolve. Only a timeout cancel (after resolutionDeadline) is allowed.
        if (hasActivity) {
            require(isTimeout, "Market has activity: resolution required");
        } else {
            require(msg.sender == m.creator || msg.sender == admin || isTimeout, "Not authorized");
        }

        m.status = MarketStatus.Cancelled;
        _cancelAllOrders(_marketId);

        // BIZ-07: if cancelled by timeout (creator failed to resolve by resolutionDeadline),
        // confiscate accrued creator fees to treasury — no free ride for abandoning a market.
        bool isTimeoutCancel = block.timestamp > m.resolutionDeadline;
        if (isTimeoutCancel) {
            uint256 abandonedFees = creatorAccruedFees[_marketId];
            if (abandonedFees > 0) {
                creatorAccruedFees[_marketId] = 0;
                treasuryBalance += abandonedFees;
            }
        }

        if (!m.creatorCollateralReturned) {
            uint256 col = CREATOR_COLLATERAL;
            m.creatorCollateralReturned = true; // Effect before interaction (CEI fix — EXEC-03)
            usdm.safeTransfer(m.creator, col);
        }

        // BIZ-05: if no trades occurred, return the LMSR subsidy to the creator
        // (claimCancelRefund requires allTotal > 0 and would permanently strand the subsidy otherwise)
        uint256 nOpts = m.options.length;
        uint256 totalSupply = 0;
        for (uint256 i = 0; i < nOpts; i++) totalSupply += optionSupply[_marketId][i];
        if (totalSupply == 0 && m.subsidyDeposited > 0) {
            uint256 sub = m.subsidyDeposited;
            m.subsidyDeposited = 0;
            usdm.safeTransfer(m.creator, sub);
        }

        emit MarketCancelled(_marketId);
    }

    /// @dev Fix GPT-R3-3: Disputed status added so a market under active dispute can still be admin-slashed.
    ///      When slashing a Disputed market, the dispute collateral is also swept to treasury to avoid
    ///      funds being permanently stranded (disputer loses collateral as the market is being punished).
    function slashMarket(uint256 _marketId, string calldata _reason) external onlyAdmin nonReentrant {
        Market storage m = _markets[_marketId];
        require(
            m.status == MarketStatus.Active ||
            m.status == MarketStatus.BettingClosed ||
            m.status == MarketStatus.Resolved ||
            m.status == MarketStatus.Disputed,
            "Cannot slash"
        );

        // BIZ-04: if the market was Disputed, the disputer identified a problem that triggered the slash.
        // Return their collateral — they should not be punished for raising a valid concern.
        // (Previously swept to treasury, which disincentivised honest disputes.)
        bool hasDisputer = m.status == MarketStatus.Disputed && m.disputer != address(0);

        m.status = MarketStatus.Slashed;
        _cancelAllOrders(_marketId);

        if (!m.creatorCollateralReturned) {
            uint256 col = CREATOR_COLLATERAL;
            m.creatorCollateralReturned = true;
            treasuryBalance += col;
        }

        uint256 slashedFees = creatorAccruedFees[_marketId];
        if (slashedFees > 0) {
            creatorAccruedFees[_marketId] = 0;
            treasuryBalance += slashedFees;
            m.creatorFeePaid = true;
            emit CreatorFeesSlashed(_marketId, slashedFees);
        }

        // BIZ-05: if no trades occurred, move stranded subsidy to treasury (creator is being slashed)
        uint256 nOpts_ = m.options.length;
        uint256 totalSupply_ = 0;
        for (uint256 i = 0; i < nOpts_; i++) totalSupply_ += optionSupply[_marketId][i];
        if (totalSupply_ == 0 && m.subsidyDeposited > 0) {
            uint256 sub = m.subsidyDeposited;
            m.subsidyDeposited = 0;
            treasuryBalance += sub;
        }

        emit MarketSlashed(_marketId, m.creator, _reason);

        // Interaction after all state changes (CEI): return disputer collateral if applicable
        if (hasDisputer) {
            usdm.safeTransfer(m.disputer, DISPUTE_COLLATERAL);
        }
    }

    function closeBetting(uint256 _marketId) external nonReentrant {
        Market storage m = _markets[_marketId];
        require(m.status == MarketStatus.Active, "Not active");
        require(block.timestamp >= m.bettingDeadline, "Not over");
        m.status = MarketStatus.BettingClosed;
        emit BettingClosed(_marketId);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          ADMIN
    // ══════════════════════════════════════════════════════════════════

    /// @notice Redirect resolver pool fees. Initially points to admin EOA; post-TGE should point
    ///         to the staking/resolver smart contract. AC-06: once set to a non-admin contract,
    /// @notice Step 1: request a resolver pool address change. Enforces a 24h timelock.
    function requestResolverPoolChange(address _addr) external onlyAdmin {
        require(_addr != address(0), "Zero address");
        require(pendingResolverPoolAddress == address(0), "Change already pending");
        pendingResolverPoolAddress = _addr;
        pendingResolverPoolReadyAt = block.timestamp + TREASURY_WITHDRAWAL_DELAY;
        emit ResolverPoolChangeRequested(_addr, pendingResolverPoolReadyAt);
    }

    /// @notice Step 2: execute the resolver pool address change after the 24h delay.
    function executeResolverPoolChange() external onlyAdmin {
        require(pendingResolverPoolAddress != address(0), "No pending change");
        require(block.timestamp >= pendingResolverPoolReadyAt, "Timelock not elapsed");
        address newAddr = pendingResolverPoolAddress;
        pendingResolverPoolAddress = address(0);
        pendingResolverPoolReadyAt = 0;
        resolverPoolAddress = newAddr;
        emit ResolverPoolUpdated(newAddr);
    }

    /// @notice Cancel a pending resolver pool address change.
    function cancelResolverPoolChange() external onlyAdmin {
        require(pendingResolverPoolAddress != address(0), "No pending change");
        address cancelled = pendingResolverPoolAddress;
        pendingResolverPoolAddress = address(0);
        pendingResolverPoolReadyAt = 0;
        emit ResolverPoolChangeCancelled(cancelled);
    }

    /// @notice Withdraw accumulated resolver fees. Only the resolverPoolAddress can call and receive.
    ///         (Initially = admin EOA; post-TGE: setResolverPoolAddress(stakingContract))
    ///         Admin cannot drain to an arbitrary address — ECON-03 fix.
    function withdrawResolverPool(uint256 _amount) external {
        require(msg.sender == resolverPoolAddress, "Not authorized");
        require(_amount <= resolverPoolBalance, "Insufficient resolver balance");
        resolverPoolBalance -= _amount;
        usdm.safeTransfer(resolverPoolAddress, _amount);
    }

    /// @notice Step 1: request a treasury withdrawal. Funds are reserved immediately but locked for
    ///         TREASURY_WITHDRAWAL_DELAY (24h), giving the community a window to react. (AC-03 fix)
    function requestTreasuryWithdrawal(address _to, uint256 _amount) external onlyAdmin {
        require(_to != address(0), "Invalid address");
        require(_amount > 0, "Zero amount");
        require(_amount <= treasuryBalance, "Insufficient treasury");
        require(pendingWithdrawalAmount == 0, "Withdrawal already pending");
        treasuryBalance -= _amount; // reserve immediately to prevent double-request
        pendingWithdrawalTo      = _to;
        pendingWithdrawalAmount  = _amount;
        pendingWithdrawalReadyAt = block.timestamp + TREASURY_WITHDRAWAL_DELAY;
        emit TreasuryWithdrawalRequested(_to, _amount, pendingWithdrawalReadyAt);
    }

    /// @notice Step 2: execute a pending treasury withdrawal after the delay has elapsed.
    function executeTreasuryWithdrawal() external onlyAdmin {
        require(pendingWithdrawalAmount > 0, "No pending withdrawal");
        require(block.timestamp >= pendingWithdrawalReadyAt, "Withdrawal delay not elapsed");
        uint256 amount = pendingWithdrawalAmount;
        address to     = pendingWithdrawalTo;
        pendingWithdrawalAmount  = 0;
        pendingWithdrawalTo      = address(0);
        pendingWithdrawalReadyAt = 0;
        usdm.safeTransfer(to, amount);
        emit TreasuryWithdrawn(to, amount);
    }

    /// @notice Cancel a pending treasury withdrawal and return the reserved funds to treasuryBalance.
    function cancelTreasuryWithdrawal() external onlyAdmin {
        require(pendingWithdrawalAmount > 0, "No pending withdrawal");
        uint256 amount = pendingWithdrawalAmount;
        pendingWithdrawalAmount  = 0;
        pendingWithdrawalTo      = address(0);
        pendingWithdrawalReadyAt = 0;
        treasuryBalance += amount;
        emit TreasuryWithdrawalCancelled(amount);
    }

    /// @notice Step 1: nominate a new admin. Does not take effect until acceptAdmin() is called.
    ///         Two-step pattern prevents irreversible loss from typos or clipboard hijacking (AC-02 fix).
    function transferAdmin(address _newAdmin) external onlyAdmin {
        require(_newAdmin != address(0), "Invalid address");
        pendingAdmin = _newAdmin;
    }

    /// @notice Step 2: new admin accepts the role. Must be called by the nominated address.
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Not pending admin");
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    /// @notice Update the dispute resolver address (independent from admin multisig).
    function setDisputeResolver(address _resolver) external onlyAdmin {
        require(_resolver != address(0), "Zero address");
        disputeResolver = _resolver;
        emit DisputeResolverUpdated(_resolver);
    }

    /// @notice Halt new trades and market creation. Exits (cancelOrder, redeemWinnings) stay open.
    ///         Pause expires automatically after MAX_PAUSE_DURATION (72h) — anyone can then trade again.
    function pause() external onlyAdmin {
        require(!paused, "Already paused");
        paused = true;
        pausedAt = block.timestamp;
        emit Paused(msg.sender);
    }

    /// @notice Resume normal operation.
    ///         Admin can unpause at any time; after 72h anyone can force-unpause.
    function unpause() external {
        require(paused, "Not paused");
        require(msg.sender == admin || block.timestamp >= pausedAt + MAX_PAUSE_DURATION, "Not authorized");
        paused = false;
        pausedAt = 0;
        emit Unpaused(msg.sender);
    }

    /// @notice Distribute the monthly dispute lottery pool equally to all successful disputers of that month.
    /// @dev Admin-callable; distributable only after the month has fully elapsed.
    ///      Each address in _monthlyDisputers receives an equal share regardless of how many markets
    ///      they disputed (one entry per successful dispute — duplication is intentional weighting).
    function distributeMonthlyDisputeRewards(uint256 _month) external onlyAdmin nonReentrant {
        uint256 currentMonth = block.timestamp / DISPUTE_MONTH_DURATION;
        require(_month < currentMonth, "Month not yet over");
        require(!monthlyRewardsDistributed[_month], "Already distributed");
        monthlyRewardsDistributed[_month] = true;

        uint256 pool = monthlyDisputePool[_month];
        address[] storage disputers = _monthlyDisputers[_month];
        uint256 count = disputers.length;
        require(pool > 0 && count > 0, "Nothing to distribute");

        uint256 share = pool / count;
        for (uint256 i = 0; i < count; i++) {
            usdm.safeTransfer(disputers[i], share);
        }
        // Any dust from integer division stays in treasury — subtract distributed amount
        uint256 distributed = share * count;
        uint256 dust = pool - distributed;
        if (dust > 0) treasuryBalance += dust;

        emit MonthlyDisputeRewardsDistributed(_month, pool, count);
    }

    // ══════════════════════════════════════════════════════════════════
    //                          VIEWS
    // ══════════════════════════════════════════════════════════════════

    function getMarketInfo(uint256 _marketId) external view returns (
        address creator, string memory question, string[] memory options,
        Category category, string memory resolutionCriteria, string memory imageUrl,
        uint256 bettingDeadline, uint256 resolutionDeadline,
        MarketStatus status, uint256 winningOption, uint256 totalVolume, bool isAdminMarket
    ) {
        Market storage m = _markets[_marketId];
        require(_marketId < nextMarketId, "Market does not exist"); // INV-07
        return (m.creator, m.question, m.options, m.category, m.resolutionCriteria,
                m.imageUrl, m.bettingDeadline, m.resolutionDeadline, m.status,
                m.winningOption, m.totalVolume, m.isAdminMarket);
    }

    function getPoolBalance(uint256 _marketId)  external view returns (uint256) { require(_marketId < nextMarketId, "Market does not exist"); Market storage m = _markets[_marketId]; return m.poolBalance + m.subsidyDeposited; }
    function getImpliedPrices(uint256 _marketId) external view returns (uint256[] memory prices) {
        Market storage m = _markets[_marketId];
        require(_marketId < nextMarketId, "Market does not exist"); // INV-07
        uint256 nOpts = m.options.length; // OPT-01
        prices = new uint256[](nOpts);
        for (uint256 i = 0; i < nOpts; i++) prices[i] = getPrice(_marketId, i);
    }
    function getQuantities(uint256 _marketId)   external view returns (uint256[] memory) { require(_marketId < nextMarketId, "Market does not exist"); return _markets[_marketId].quantities; }
    function getSubsidy(uint256 _marketId)      external view returns (uint256 deposited, uint256 b) {
        require(_marketId < nextMarketId, "Market does not exist"); // INV-07
        return (_markets[_marketId].subsidyDeposited, _markets[_marketId].b);
    }
    function getCreatorFees(uint256 _marketId)  external view returns (uint256 accrued, bool claimed) {
        require(_marketId < nextMarketId, "Market does not exist"); // INV-07
        return (creatorAccruedFees[_marketId], _markets[_marketId].creatorFeePaid);
    }
    function getBidBook(uint256 _marketId, uint256 _opt) external view returns (uint256[] memory) { return _bidBook[_marketId][_opt]; }
    function getAskBook(uint256 _marketId, uint256 _opt) external view returns (uint256[] memory) { return _askBook[_marketId][_opt]; }

    function getOrderInfo(uint256 _orderId) external view returns (
        address maker, uint256 marketId, uint256 optionIndex,
        OrderSide side, uint256 pricePerShare, uint256 quantityRemaining,
        uint256 usdmEscrowed, bool active, uint256 placedAt
    ) {
        Order storage o = orders[_orderId];
        return (o.maker, o.marketId, o.optionIndex, o.side,
                o.pricePerShare, o.quantityRemaining, o.usdmEscrowed, o.active, o.placedAt);
    }

    function isDisputeWindowOpen(uint256 _marketId) external view returns (bool) {
        Market storage m = _markets[_marketId];
        return m.status == MarketStatus.Resolved && block.timestamp < m.resolvedAt + DISPUTE_WINDOW;
    }

    /// @notice Returns true when burnLosingShares can be called by the keeper.
    function isBurnReady(uint256 _marketId) external view returns (bool) {
        Market storage m = _markets[_marketId];
        return m.status == MarketStatus.Finalized &&
               block.timestamp >= m.finalizedAt + BURN_DELAY &&
               !m.losingSharesBurned;
    }

    /// @notice Returns the list of disputer addresses that won in a given month (one entry per winning dispute).
    function getMonthlyDisputers(uint256 _month) external view returns (address[] memory) {
        return _monthlyDisputers[_month];
    }

    // ══════════════════════════════════════════════════════════════════
    //                         INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════════

    /// @dev Q7: enforce 0x-prefixed, exactly 66-char, lowercase hex conditionId.
    ///      Prevents duplicates (same hash but different casing) slipping past the keccak guard.
    function _validateConditionId(string calldata _id) internal pure {
        bytes memory b = bytes(_id);
        require(b.length == 66, "ConditionId: must be 66 chars");
        require(b[0] == '0' && b[1] == 'x', "ConditionId: must start with 0x");
        for (uint256 i = 2; i < 66; i++) {
            bytes1 c = b[i];
            require(
                (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'),
                "ConditionId: lowercase hex only"
            );
        }
    }

    /// @dev C(q) = b * ln( Σ exp(q[i]/b) )  — LMSR cost function, 1e18 units.
    ///      Guards against PRBMath SD59x18 exp() overflow at x > 133.08e18 (MATH-02/01/04 fix).
    function _lmsrCost(uint256[] memory q, uint256 b_) internal pure returns (uint256) {
        SD59x18 sum = wrap(0);
        for (uint256 i = 0; i < q.length; i++) {
            int256 arg = SafeCast.toInt256(q[i] * 1e18 / b_);
            require(arg <= EXP_MAX_ARG, "LMSR: exp overflow");
            sum = add(sum, exp(wrap(arg)));
        }
        return uint256(unwrap(mul(wrap(SafeCast.toInt256(b_)), ln(sum))));
    }

    function _tokenId(uint256 _marketId, uint256 _opt) internal pure returns (uint256) {
        return _marketId * MAX_OPTIONS + _opt;
    }

    /// @dev Collect fees from amount. Returns netAmount. Pure state (no external calls) — CEI safe.
    ///      Imported markets pay 0.5% creator fee; the saved 0.5% vs regular markets goes to treasury.
    function _collectFees(Market storage m, uint256 _marketId, uint256 amount) internal returns (uint256 netAmount) {
        uint256 effCreatorBps = m.isImportedMarket ? importedCreatorFeeBps : creatorFeeBps;
        // For imported markets: treasury gets its normal cut + the 0.5% difference
        uint256 effTreasuryBps = m.isImportedMarket
            ? treasuryFeeBps + (creatorFeeBps - importedCreatorFeeBps)
            : treasuryFeeBps;

        uint256 totalBps    = effCreatorBps + effTreasuryBps + resolverFeeBps;
        uint256 totalFee    = (amount * totalBps)       / 10000;
        uint256 creatorCut  = (amount * effCreatorBps)  / 10000;
        uint256 treasuryCut = (amount * effTreasuryBps) / 10000;
        require(creatorCut + treasuryCut <= totalFee, "Fee invariant"); // MATH-06: guard
        uint256 resolverCut = totalFee - creatorCut - treasuryCut;
        netAmount           = amount - totalFee;

        treasuryBalance     += treasuryCut;
        resolverPoolBalance += resolverCut;

        uint256 emittedCreatorCut = creatorCut;
        if (creatorCut > 0) {
            if (m.isAdminMarket || m.creator == address(0)) {
                treasuryBalance  += creatorCut;
                emittedCreatorCut = 0;
            } else {
                creatorAccruedFees[_marketId] += creatorCut;
            }
        }
        emit FeeCollected(_marketId, m.creator, emittedCreatorCut, treasuryCut, resolverCut);
    }

    /// @dev Cancel all resting CLOB orders for a market; return escrowed funds/shares to makers.
    ///      REX4-02: Each external call consumes REX4 frame budget (98/100 per frame).
    ///      When gasleft() < REX4_MIN_GAS_PER_ITER the order is marked inactive without transfer —
    ///      the maker's escrowed amount is preserved so reclaimCancelledOrder() can return it later.
    ///      OrderEscrowDeferred is emitted to allow off-chain monitoring.
    function _cancelAllOrders(uint256 _marketId) internal {
        Market storage m = _markets[_marketId];
        uint256 nOpts = m.options.length; // OPT-01: cache length to avoid repeated SLOAD
        for (uint256 opt = 0; opt < nOpts; opt++) {
            // Cancel ask orders — return escrowed shares
            uint256[] storage asks = _askBook[_marketId][opt];
            for (uint256 i = 0; i < asks.length; i++) {
                Order storage ask = orders[asks[i]];
                if (!ask.active || ask.quantityRemaining == 0) continue;
                ask.active = false;
                if (userOrderCount[_marketId][ask.maker] > 0) userOrderCount[_marketId][ask.maker]--;
                if (marketOrderCount[_marketId] > 0) marketOrderCount[_marketId]--;
                emit OrderCancelled(asks[i]);
                if (gasleft() >= REX4_MIN_GAS_PER_ITER) {
                    uint256 rem = ask.quantityRemaining;
                    ask.quantityRemaining = 0;
                    // ATCK-09: try/catch prevents a malicious maker's onERC1155Received revert
                    // from blocking the entire cancellation loop. Deferred to reclaimCancelledOrder.
                    try this.safeTransferFrom(address(this), ask.maker, _tokenId(_marketId, opt), rem, "") {
                        // success
                    } catch {
                        ask.quantityRemaining = rem; // restore for reclaim
                        emit OrderEscrowDeferred(asks[i]);
                    }
                } else {
                    // REX4-02: deferred — quantityRemaining preserved; maker calls reclaimCancelledOrder.
                    emit OrderEscrowDeferred(asks[i]);
                }
            }
            // Cancel bid orders — return escrowed USDm
            uint256[] storage bids = _bidBook[_marketId][opt];
            for (uint256 i = 0; i < bids.length; i++) {
                Order storage bid = orders[bids[i]];
                if (!bid.active || bid.usdmEscrowed == 0) continue;
                bid.active = false;
                if (userOrderCount[_marketId][bid.maker] > 0) userOrderCount[_marketId][bid.maker]--;
                if (marketOrderCount[_marketId] > 0) marketOrderCount[_marketId]--;
                emit OrderCancelled(bids[i]);
                if (gasleft() >= REX4_MIN_GAS_PER_ITER) {
                    // Normal path: return escrowed USDm immediately.
                    uint256 escrowed = bid.usdmEscrowed;
                    bid.usdmEscrowed      = 0;
                    bid.quantityRemaining = 0;
                    usdm.safeTransfer(bid.maker, escrowed);
                } else {
                    // REX4-02: deferred — usdmEscrowed preserved; maker calls reclaimCancelledOrder.
                    emit OrderEscrowDeferred(bids[i]);
                }
            }
        }
    }

    /// @notice Reclaim escrowed funds from an order that was cancelled by market resolution but whose
    ///         transfer was deferred due to REX4 gas budget constraints (OrderEscrowDeferred emitted).
    ///         Also handles normal order cancellations where the maker forgot to call cancelOrder.
    /// @dev    Callable only on inactive orders that still have escrowed assets.
    ///         Market must be Resolved, Finalized, Cancelled, or Slashed.
    function reclaimCancelledOrder(uint256 _orderId) external nonReentrant {
        Order storage o = orders[_orderId];
        require(o.maker == msg.sender, "Not your order");
        require(!o.active, "Order still active: use cancelOrder");

        uint256 qty      = o.quantityRemaining;
        uint256 escrowed = o.usdmEscrowed;
        require(qty > 0 || escrowed > 0, "Nothing to reclaim");

        Market storage m = _markets[o.marketId];
        require(
            m.status == MarketStatus.Resolved   ||
            m.status == MarketStatus.Disputed   || // BIZ-10: deferred orders reachable during dispute
            m.status == MarketStatus.Finalized  ||
            m.status == MarketStatus.Cancelled  ||
            m.status == MarketStatus.Slashed,
            "Market not settled"
        );

        // Effects before interactions (CEI)
        o.quantityRemaining = 0;
        o.usdmEscrowed      = 0;

        if (o.side == OrderSide.BUY && escrowed > 0) {
            usdm.safeTransfer(msg.sender, escrowed);
        } else if (o.side == OrderSide.SELL && qty > 0) {
            _safeTransferFrom(address(this), msg.sender, _tokenId(o.marketId, o.optionIndex), qty, "");
        }
    }

    /// @dev Remove all inactive / empty orders from a book array in-place.
    ///      Called immediately after cancellation (fix F-DS-M02) and after matching.
    function _cleanBook(uint256[] storage book) internal {
        uint256 writeIdx = 0;
        for (uint256 readIdx = 0; readIdx < book.length; readIdx++) {
            Order storage o = orders[book[readIdx]];
            if (o.active && o.quantityRemaining > 0) {
                book[writeIdx++] = book[readIdx];
            }
        }
        while (book.length > writeIdx) book.pop();
    }

    /// @dev Insert orderId into a sorted book, maintaining price order and FIFO within price.
    ///      ascending=true  → lowest price first (ask book)
    ///      ascending=false → highest price first (bid book)
    function _insertSorted(uint256[] storage book, uint256 orderId, uint256 price, bool ascending) internal {
        uint256 insertAt = book.length;
        for (uint256 i = 0; i < book.length; i++) {
            uint256 p = orders[book[i]].pricePerShare;
            if (ascending ? p > price : p < price) { insertAt = i; break; }
        }
        book.push(0);
        for (uint256 i = book.length - 1; i > insertAt; i--) book[i] = book[i - 1];
        book[insertAt] = orderId;
    }

    // ══════════════════════════════════════════════════════════════════
    //                       COMMUNITY UPVOTE
    // ══════════════════════════════════════════════════════════════════

    /// @notice Upvote a community-created market. One vote per address per market.
    ///         No USDm required — only a MegaETH transaction (gas ~60k intrinsic + SSTORE).
    ///         Vote count feeds the off-chain "Trending" sort on the front-end.
    /// @param  _marketId  Market to upvote.
    function upvoteMarket(uint256 _marketId) external onlyWhitelisted nonReentrant {
        Market storage m = _markets[_marketId];
        require(_marketId < nextMarketId, "Market does not exist"); // INV-07
        require(
            m.status == MarketStatus.Active || m.status == MarketStatus.BettingClosed,
            "Market not open"
        );
        require(!hasUpvoted[_marketId][msg.sender], "Already upvoted");

        hasUpvoted[_marketId][msg.sender] = true;
        uint256 newCount = ++upvoteCount[_marketId];

        emit MarketUpvoted(_marketId, msg.sender, newCount);
    }

    // ── ERC-1155 receiver hooks (required for share escrow) ──
    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory) public pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
