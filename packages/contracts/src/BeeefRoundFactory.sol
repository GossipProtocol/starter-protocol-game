// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@solady/auth/Ownable.sol";
import { LibClone } from "@solady/utils/LibClone.sol";
import { LibString } from "@solady/utils/LibString.sol";
import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";
import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@v4-core/interfaces/callback/IUnlockCallback.sol";
import { LPFeeLibrary } from "@v4-core/libraries/LPFeeLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";

import { BeeefFeeSplitter } from "src/BeeefFeeSplitter.sol";
import { BeeefOracle } from "src/BeeefOracle.sol";
import { BeeefRegistry } from "src/BeeefRegistry.sol";
import {
    BeneficiaryData,
    CreateParams,
    Curve,
    IAirlock,
    IPredictionMigrator,
    InitData
} from "src/interfaces/IDoppler.sol";
import { BeeefEntryData } from "src/libraries/BeeefEntryData.sol";

/**
 * @title BeeefRoundFactory
 * @notice Runs beeef pairs as rolling rounds. Each round is one BeeefOracle clone plus two Doppler prediction-market
 * entries (side A and side B) sharing that oracle, each seeded with a small buy so that either side can win and be
 * claimed. When a round ends, `rollover(pairId)` starts the next one for the same pair at the exact end time, with
 * the previous end snapshot as its start price, so there is no gap and no overlap. Rollover waits for the market when
 * the next round would not fit inside the trading session.
 * @dev Entries are created through Airlock with PredictionMigrator as the liquidity migrator and
 * DopplerHookInitializer + BeeefClockHook as the pool initializer, mirroring Doppler's PredictionMarket integration
 * test: empty beneficiaries and `farTick == startingTick`, but with a non-zero LP fee so the integrator earns fees at
 * migration. BeeefClockHook blocks sells, locks buys at `lockTime` and applies the falling share multiplier.
 *
 * The seed buy is executed here through a PoolManager unlock callback rather than through a bundler contract, so the
 * factory depends only on the PoolManager and the Airlock interfaces it declares itself.
 */
contract BeeefRoundFactory is Ownable, IUnlockCallback {
    using SafeTransferLib for address;

    bytes32 public constant ENTRY_ID_A = keccak256("beeef.entry.A");
    bytes32 public constant ENTRY_ID_B = keccak256("beeef.entry.B");
    uint256 public constant NO_ROUND = type(uint256).max;

    /// @dev Encoding used for `tokenFactoryData`. Robinhood Chain runs DopplerERC20V1Factory; the local test
    /// deployment uses CloneERC20Factory.
    enum TokenFactoryKind {
        CloneERC20,
        DopplerERC20V1
    }

    struct Modules {
        address airlock;
        address poolManager;
        address poolInitializer;
        address migrator;
        address dopplerHook;
        address tokenFactory;
        TokenFactoryKind tokenFactoryKind;
        address governanceFactory;
        address numeraire;
        address oracleImplementation;
        address feeSplitterImplementation;
    }

    /// @notice A matchup (stock A vs stock B). Created on first use; many series can run on the same pair at once.
    struct Pair {
        address stockA;
        address stockB;
        bool active;
    }

    /// @notice A creator's run of rounds on one pair. One-off series have exactly one round. Recurring series roll
    /// over until they run out of rounds, pass `endTime`, or are stopped.
    struct Series {
        uint256 pairId;
        uint64 duration;
        bool recurring;
        bool active;
        /// @dev 0 = no round limit.
        uint32 roundsTotal;
        uint32 roundsPlayed;
        /// @dev No new round starts at or after this time. 0 = no end date.
        uint64 endTime;
        address creator;
        address feeSplitter;
        /// @dev USD per round, split evenly between the two sides' seed buys.
        uint256 seedPerRound;
        /// @dev Unspent seed held for future rounds.
        uint256 seedBalance;
        uint256 lastRoundId;
    }

    struct Round {
        uint256 seriesId;
        uint256 pairId;
        uint32 roundNumber;
        uint256 prevRoundId;
        address oracle;
        address entryA;
        address entryB;
        uint64 startTime;
        uint64 endTime;
        uint64 lockTime;
        uint64 floorWad;
        bool carriedStart;
    }

    /// @notice Where a series' fees go, passed at creation.
    struct FeeSplit {
        address[] recipients;
        uint16[] bps;
    }

    /// @notice How a recurring series ends. Both zero = only when stopped.
    struct SeriesEnd {
        uint32 rounds;
        uint64 endTime;
    }

    struct SeedCallback {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
    }

    // ==================== Errors ====================

    error StockNotAllowed(address stock);
    error SameStock();
    error DurationNotAllowed(uint256 duration);
    error MarketClosed();
    error SeedTooSmall();
    error SeedFundsLow(uint256 needed, uint256 available);
    error InvalidSeriesEnd();
    error NotPoolManager();
    error SeedNotFullySpent();
    error UnknownRound();
    error UnknownPair();
    error UnknownSeries();
    error PairPaused();
    error NotRecurring();
    error SeriesNotActive();
    error NotCreatorOrOwner();
    error RoundNotOver();
    error NotOneOff();
    error RematchExists(uint256 rematchRoundId);

    // ==================== Events ====================

    event PairCreated(uint256 indexed pairId, address stockA, address stockB);
    event PairActiveSet(uint256 indexed pairId, bool active);
    event SeriesCreated(
        uint256 indexed seriesId,
        uint256 indexed pairId,
        address indexed creator,
        uint64 duration,
        bool recurring,
        uint32 roundsTotal,
        uint64 endTime,
        uint256 seedPerRound,
        address feeSplitter
    );
    event SeriesStopped(uint256 indexed seriesId, uint256 refund);
    event SeriesExhausted(uint256 indexed seriesId, uint256 refund);
    event RematchStarted(
        uint256 indexed prevRoundId,
        uint256 indexed roundId,
        uint256 indexed seriesId,
        address starter,
        bool sideA,
        uint256 amount
    );
    event SeedToppedUp(uint256 indexed seriesId, address indexed from, uint256 amount, uint256 seedBalance);
    event RoundCreated(
        uint256 indexed roundId,
        uint256 indexed seriesId,
        address indexed oracle,
        uint256 pairId,
        uint32 roundNumber,
        address entryA,
        address entryB,
        uint64 startTime,
        uint64 endTime,
        uint64 lockTime,
        uint64 floorWad,
        uint256 prevRoundId,
        bool carriedStart
    );
    event Seeded(uint256 indexed roundId, address indexed entry, uint256 amountIn, uint256 tokensOut);

    // ==================== Storage ====================

    IAirlock public immutable airlock;
    IPoolManager public immutable poolManager;
    address public immutable poolInitializer;
    IPredictionMigrator public immutable migrator;
    address public immutable dopplerHook;
    address public immutable tokenFactory;
    TokenFactoryKind public immutable tokenFactoryKind;
    address public immutable governanceFactory;
    address public immutable numeraire;
    address public immutable oracleImplementation;
    address public immutable feeSplitterImplementation;

    /// @notice Stock allowlist, durations, market calendar, pool / oracle / clock settings, min seed, platform fee.
    BeeefRegistry public immutable registry;

    Pair[] internal _pairs;
    mapping(bytes32 key => uint256 pairIdPlusOne) internal _pairOfKey;
    Series[] internal _series;
    Round[] internal _rounds;
    mapping(address oracle => uint256 roundIdPlusOne) internal _roundOfOracle;
    mapping(uint256 roundId => uint256 rematchRoundIdPlusOne) internal _rematchOf;
    /// @notice Tick spacing each entry's pool was created with (pool config can change for later rounds).
    mapping(address entry => int24) public tickSpacingOf;

    constructor(address owner_, Modules memory m, BeeefRegistry registry_) {
        _initializeOwner(owner_);
        airlock = IAirlock(m.airlock);
        poolManager = IPoolManager(m.poolManager);
        poolInitializer = m.poolInitializer;
        migrator = IPredictionMigrator(m.migrator);
        dopplerHook = m.dopplerHook;
        tokenFactory = m.tokenFactory;
        tokenFactoryKind = m.tokenFactoryKind;
        governanceFactory = m.governanceFactory;
        numeraire = m.numeraire;
        oracleImplementation = m.oracleImplementation;
        feeSplitterImplementation = m.feeSplitterImplementation;
        registry = registry_;
    }

    // ==================== Series and rounds ====================

    /// @notice A single round. It starts now, or at the next market open when the market is closed, and takes a
    /// fresh start price. The caller pays one round's seed (`seedPerRound`, half per side) and gets the seed tokens.
    function createOneOff(
        address stockA,
        address stockB,
        uint64 duration,
        FeeSplit calldata fees,
        uint256 seedPerRound
    ) external returns (uint256 seriesId, uint256 roundId) {
        seriesId = _createSeries(stockA, stockB, duration, false, SeriesEnd(1, 0), fees, seedPerRound, seedPerRound);
        roundId = _startSeriesRound(seriesId, registry.nextStart(block.timestamp, duration), address(0));
        _series[seriesId].active = false; // nothing left to roll over
    }

    /// @notice Starts the rematch of a finished one-off round. Nothing rematches on its own: the first player who bets
    /// on it creates it, and that bet is the rematch's first bet (placed at the 1.00x start). Same pair, same length
    /// and the same fee recipients as the original; a fresh start price, now or at the next open.
    /// The starter pays `amount` for their side plus the minimum seed for the other side (so either side can win and
    /// be claimed) and receives the tokens of both buys. Each round can be rematched once; later players join the
    /// existing rematch (`rematchOf`).
    function rematch(
        uint256 prevRoundId,
        bool sideA,
        uint256 amount
    ) external returns (uint256 seriesId, uint256 roundId) {
        Round storage prev = _round(prevRoundId);
        uint256 existing = _rematchOf[prevRoundId];
        if (existing != 0) revert RematchExists(existing - 1);
        Series storage prevSeries = _series[prev.seriesId];
        require(!prevSeries.recurring, NotOneOff());
        require(block.timestamp >= prev.endTime, RoundNotOver());
        require(_pairs[prevSeries.pairId].active, PairPaused());
        uint256 otherSide = registry.minSeed();
        if (otherSide == 0) otherSide = 1;
        require(amount >= otherSide, SeedTooSmall());

        uint256 cost = amount + otherSide;
        seriesId = _series.length;
        _series.push(
            Series({
                pairId: prevSeries.pairId,
                duration: prevSeries.duration,
                recurring: false,
                active: true,
                roundsTotal: 1,
                roundsPlayed: 0,
                endTime: 0,
                creator: msg.sender,
                feeSplitter: prevSeries.feeSplitter,
                seedPerRound: cost,
                seedBalance: cost,
                lastRoundId: NO_ROUND
            })
        );
        numeraire.safeTransferFrom(msg.sender, address(this), cost);
        emit SeriesCreated(
            seriesId, prevSeries.pairId, msg.sender, prevSeries.duration, false, 1, 0, cost, prevSeries.feeSplitter
        );

        (uint256 seedA, uint256 seedB) = sideA ? (amount, otherSide) : (otherSide, amount);
        roundId = _startSeriesRound(
            seriesId, registry.nextStart(block.timestamp, prevSeries.duration), address(0), seedA, seedB
        );
        _series[seriesId].active = false;
        _rematchOf[prevRoundId] = roundId + 1;
        emit RematchStarted(prevRoundId, roundId, seriesId, msg.sender, sideA, amount);
    }

    /// @notice A recurring series: rounds run back to back until `end` is reached or the series is stopped, pausing
    /// while the market is closed. The first round starts now (or at the open) with a fresh start price; every later
    /// round reuses the previous round's end price. `seedDeposit` funds the rounds and must cover at least one; it
    /// can be topped up later and any unused part is refunded when the series stops or ends.
    function createSeries(
        address stockA,
        address stockB,
        uint64 duration,
        FeeSplit calldata fees,
        SeriesEnd calldata end,
        uint256 seedPerRound,
        uint256 seedDeposit
    ) external returns (uint256 seriesId, uint256 roundId) {
        require(end.endTime == 0 || end.endTime > block.timestamp, InvalidSeriesEnd());
        seriesId = _createSeries(stockA, stockB, duration, true, end, fees, seedPerRound, seedDeposit);
        roundId = _startSeriesRound(seriesId, registry.nextStart(block.timestamp, duration), address(0));
    }

    /// @notice Starts the series' next round once the current one has ended. Permissionless (the keeper calls it right
    /// after the end). Finalizes the previous round first if nobody has.
    /// - The new round starts exactly at the previous end with the previous end price when that price is valid, the
    ///   rollover happens inside the end-snapshot window and the round fits the session; otherwise it starts at the
    ///   next moment it fits (now or the open) with a fresh start price.
    /// - When the series has played all its rounds or passed its end time it is closed instead: the unused seed is
    ///   refunded to the creator, `SeriesExhausted` is emitted and NO_ROUND is returned.
    /// - Reverts (so it can be retried) while the pair is paused or the seed balance cannot cover a round.
    function rollover(uint256 seriesId) external returns (uint256 roundId) {
        Series storage series = _getSeries(seriesId);
        require(series.recurring, NotRecurring());
        require(series.active, SeriesNotActive());
        require(_pairs[series.pairId].active, PairPaused());
        Round memory prev = _rounds[series.lastRoundId];
        require(block.timestamp >= prev.endTime, RoundNotOver());

        BeeefOracle prevOracle = BeeefOracle(prev.oracle);
        if (!prevOracle.finalized()) prevOracle.finalize();

        uint256 window = registry.oracleSettings().snapshotWindow;
        bool carry = prevOracle.hasEndSnapshot() && block.timestamp <= prev.endTime + window
            && registry.isMarketOpen(prev.endTime, prev.endTime + series.duration + window);
        uint256 start = carry ? prev.endTime : registry.nextStart(block.timestamp, series.duration);

        if (
            (series.roundsTotal != 0 && series.roundsPlayed >= series.roundsTotal)
                || (series.endTime != 0 && start >= series.endTime)
        ) {
            uint256 refund = _closeSeries(series);
            emit SeriesExhausted(seriesId, refund);
            return NO_ROUND;
        }
        require(series.seedBalance >= series.seedPerRound, SeedFundsLow(series.seedPerRound, series.seedBalance));

        roundId = _startSeriesRound(seriesId, start, carry ? prev.oracle : address(0));
    }

    /// @notice Lets the current round finish and stops the series. Unused seed goes back to the creator.
    function stopSeries(uint256 seriesId) external {
        Series storage series = _getSeries(seriesId);
        require(msg.sender == series.creator || msg.sender == owner(), NotCreatorOrOwner());
        require(series.active, SeriesNotActive());
        uint256 refund = _closeSeries(series);
        emit SeriesStopped(seriesId, refund);
    }

    /// @notice Adds seed for future rounds of an active recurring series. Anyone can top up.
    function topUpSeed(uint256 seriesId, uint256 amount) external {
        Series storage series = _getSeries(seriesId);
        require(series.recurring && series.active, SeriesNotActive());
        numeraire.safeTransferFrom(msg.sender, address(this), amount);
        series.seedBalance += amount;
        emit SeedToppedUp(seriesId, msg.sender, amount, series.seedBalance);
    }

    /// @notice Migrates every entry of a finalized round that has not migrated yet. Permissionless keeper helper;
    /// `airlock.migrate(entry)` can also be called directly.
    function settle(uint256 roundId) external {
        Round storage r = _round(roundId);
        if (!migrator.getEntryByToken(r.oracle, r.entryA).isMigrated) airlock.migrate(r.entryA);
        if (!migrator.getEntryByToken(r.oracle, r.entryB).isMigrated) airlock.migrate(r.entryB);
    }

    /// @notice True once every entry of the round migrated, i.e. the pot is complete and claims pay the full amount.
    function isSettled(uint256 roundId) external view returns (bool) {
        Round storage r = _round(roundId);
        return migrator.getEntryByToken(r.oracle, r.entryA).isMigrated
            && migrator.getEntryByToken(r.oracle, r.entryB).isMigrated;
    }

    // ==================== Seeding (PoolManager callback) ====================

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), NotPoolManager());
        SeedCallback memory cb = abi.decode(data, (SeedCallback));

        BalanceDelta delta = poolManager.swap(
            cb.key,
            IPoolManager.SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: -int256(cb.amountIn),
                sqrtPriceLimitX96: cb.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 inDelta = cb.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = cb.zeroForOne ? delta.amount1() : delta.amount0();
        require(inDelta < 0 && outDelta > 0 && uint256(uint128(-inDelta)) == cb.amountIn, SeedNotFullySpent());

        Currency input = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        Currency output = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;

        poolManager.sync(input);
        Currency.unwrap(input).safeTransfer(address(poolManager), cb.amountIn);
        poolManager.settle();

        uint256 amountOut = uint256(uint128(outDelta));
        poolManager.take(output, cb.recipient, amountOut);
        return abi.encode(amountOut);
    }

    // ==================== Views ====================

    function pairCount() external view returns (uint256) {
        return _pairs.length;
    }

    function getPair(uint256 pairId) external view returns (Pair memory) {
        require(pairId < _pairs.length, UnknownPair());
        return _pairs[pairId];
    }

    /// @notice The pair id for two stocks (either order), or reverts if no series has used them yet.
    function pairIdOf(address stockA, address stockB) external view returns (uint256) {
        uint256 idPlusOne = _pairOfKey[_pairKey(stockA, stockB)];
        require(idPlusOne != 0, UnknownPair());
        return idPlusOne - 1;
    }

    /// @notice The rematch of a finished one-off round, if a player has started one.
    function rematchOf(uint256 roundId) external view returns (bool exists, uint256 rematchRoundId) {
        uint256 idPlusOne = _rematchOf[roundId];
        return (idPlusOne != 0, idPlusOne == 0 ? NO_ROUND : idPlusOne - 1);
    }

    function seriesCount() external view returns (uint256) {
        return _series.length;
    }

    function getSeries(uint256 seriesId) external view returns (Series memory) {
        require(seriesId < _series.length, UnknownSeries());
        return _series[seriesId];
    }

    /// @notice The series' latest round (live, locked, or ended and waiting for rollover).
    function currentRoundId(uint256 seriesId) external view returns (uint256) {
        require(seriesId < _series.length, UnknownSeries());
        return _series[seriesId].lastRoundId;
    }

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _round(roundId);
    }

    function roundIdOf(address oracle) external view returns (uint256) {
        uint256 idPlusOne = _roundOfOracle[oracle];
        require(idPlusOne != 0, UnknownRound());
        return idPlusOne - 1;
    }

    /// @notice The Uniswap v4 pool key Doppler uses for an entry (dynamic fee because a Doppler hook is set).
    function poolKeyOf(address entry) public view returns (PoolKey memory key) {
        bool assetIsToken0 = entry < numeraire;
        key = PoolKey({
            currency0: Currency.wrap(assetIsToken0 ? entry : numeraire),
            currency1: Currency.wrap(assetIsToken0 ? numeraire : entry),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacingOf[entry],
            hooks: IHooks(poolInitializer)
        });
    }

    // ==================== Admin ====================

    /// @notice Switches a pair on or off. While off, no series on it can create or roll over rounds.
    function setPairActive(uint256 pairId, bool active) external onlyOwner {
        require(pairId < _pairs.length, UnknownPair());
        _pairs[pairId].active = active;
        emit PairActiveSet(pairId, active);
    }

    // ==================== Internal ====================

    function _createSeries(
        address stockA,
        address stockB,
        uint64 duration,
        bool recurring,
        SeriesEnd memory end,
        FeeSplit calldata fees,
        uint256 seedPerRound,
        uint256 seedDeposit
    ) internal returns (uint256 seriesId) {
        require(registry.stock(stockA).feed != address(0), StockNotAllowed(stockA));
        require(registry.stock(stockB).feed != address(0), StockNotAllowed(stockB));
        require(stockA != stockB, SameStock());
        require(registry.allowedDuration(duration), DurationNotAllowed(duration));
        require(seedPerRound / 2 >= registry.minSeed() && seedPerRound / 2 > 0, SeedTooSmall());
        require(seedDeposit >= seedPerRound, SeedFundsLow(seedPerRound, seedDeposit));

        uint256 pairId = _getOrCreatePair(stockA, stockB);
        require(_pairs[pairId].active, PairPaused());

        address splitter = LibClone.clone(feeSplitterImplementation);
        BeeefFeeSplitter(splitter)
            .initialize(airlock, registry.platformFeeRecipient(), registry.platformFeeBps(), fees.recipients, fees.bps);

        seriesId = _series.length;
        _series.push(
            Series({
                pairId: pairId,
                duration: duration,
                recurring: recurring,
                active: true,
                roundsTotal: end.rounds,
                roundsPlayed: 0,
                endTime: end.endTime,
                creator: msg.sender,
                feeSplitter: splitter,
                seedPerRound: seedPerRound,
                seedBalance: seedDeposit,
                lastRoundId: NO_ROUND
            })
        );
        numeraire.safeTransferFrom(msg.sender, address(this), seedDeposit);
        emit SeriesCreated(
            seriesId, pairId, msg.sender, duration, recurring, end.rounds, end.endTime, seedPerRound, splitter
        );
    }

    function _getOrCreatePair(address stockA, address stockB) internal returns (uint256 pairId) {
        bytes32 key = _pairKey(stockA, stockB);
        uint256 idPlusOne = _pairOfKey[key];
        if (idPlusOne != 0) return idPlusOne - 1;
        pairId = _pairs.length;
        _pairs.push(Pair({ stockA: stockA, stockB: stockB, active: true }));
        _pairOfKey[key] = pairId + 1;
        emit PairCreated(pairId, stockA, stockB);
    }

    /// @dev Order-independent: NVDA vs AMD and AMD vs NVDA are the same rivalry.
    function _pairKey(address a, address b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Marks the series inactive and refunds its unused seed to the creator.
    function _closeSeries(Series storage series) internal returns (uint256 refund) {
        series.active = false;
        refund = series.seedBalance;
        series.seedBalance = 0;
        if (refund > 0) numeraire.safeTransfer(series.creator, refund);
    }

    function _startSeriesRound(uint256 seriesId, uint256 start, address carryFrom) internal returns (uint256) {
        uint256 perRound = _series[seriesId].seedPerRound;
        return _startSeriesRound(seriesId, start, carryFrom, perRound / 2, perRound - perRound / 2);
    }

    function _startSeriesRound(
        uint256 seriesId,
        uint256 start,
        address carryFrom,
        uint256 seedA,
        uint256 seedB
    ) internal returns (uint256 roundId) {
        Series storage series = _series[seriesId];
        series.seedBalance -= series.seedPerRound;
        series.roundsPlayed += 1;

        roundId = _rounds.length;
        Round storage r = _rounds.push();
        r.seriesId = seriesId;
        r.pairId = series.pairId;
        r.roundNumber = series.roundsPlayed;
        r.prevRoundId = series.lastRoundId;
        r.startTime = uint64(start);
        r.endTime = uint64(start + series.duration);
        r.lockTime = registry.lockTimeFor(start, series.duration);
        r.floorWad = registry.clockSettings().floorWad;
        r.carriedStart = carryFrom != address(0);

        address oracle = _startRoundEntries(roundId, series.feeSplitter, series.creator, seedA, seedB);
        // Emitted before the start snapshot so indexers know the oracle (a factory child) before its first event.
        _emitRoundCreated(roundId);

        if (carryFrom != address(0)) {
            BeeefOracle(oracle).presetStart(BeeefOracle(carryFrom).endSnapshot());
        } else if (start <= block.timestamp) {
            // Fresh start: take the start snapshot now if the feeds allow it; otherwise anyone can take it within the
            // start window, and the round voids if nobody can.
            try BeeefOracle(oracle).snapshotStart() { } catch { }
        }

        series.lastRoundId = roundId;
        _roundOfOracle[oracle] = roundId + 1;
    }

    /// @dev Clones the round's oracle, creates and seeds both entries and registers them with the oracle.
    function _startRoundEntries(
        uint256 roundId,
        address feeSplitter,
        address creator,
        uint256 seedA,
        uint256 seedB
    ) internal returns (address oracle) {
        Round storage r = _rounds[roundId];
        Pair memory pair = _pairs[r.pairId];
        BeeefRegistry.Stock memory a = registry.stock(pair.stockA);
        BeeefRegistry.Stock memory b = registry.stock(pair.stockB);

        oracle = BeeefEntryData.startOracle(
            oracleImplementation,
            registry,
            BeeefEntryData.OracleArgs(a.feed, b.feed, pair.stockA, pair.stockB, r.startTime, r.endTime)
        );
        r.oracle = oracle;

        bytes memory clock = abi.encode(r.startTime, r.lockTime, r.floorWad);
        string memory title = BeeefEntryData.title(roundId, a.symbol, b.symbol);
        address entryA = _createEntry(roundId, oracle, ENTRY_ID_A, title, a.symbol, feeSplitter, clock);
        address entryB = _createEntry(roundId, oracle, ENTRY_ID_B, title, b.symbol, feeSplitter, clock);
        r.entryA = entryA;
        r.entryB = entryB;
        _seed(roundId, entryA, seedA, creator);
        _seed(roundId, entryB, seedB, creator);
        BeeefOracle(oracle).setEntries(entryA, entryB, address(0));
    }

    function _emitRoundCreated(uint256 roundId) internal {
        Round storage r = _rounds[roundId];
        emit RoundCreated(
            roundId,
            r.seriesId,
            r.oracle,
            r.pairId,
            r.roundNumber,
            r.entryA,
            r.entryB,
            r.startTime,
            r.endTime,
            r.lockTime,
            r.floorWad,
            r.prevRoundId,
            r.carriedStart
        );
    }

    function _getSeries(uint256 seriesId) internal view returns (Series storage) {
        require(seriesId < _series.length, UnknownSeries());
        return _series[seriesId];
    }

    function _createEntry(
        uint256 roundId,
        address oracle,
        bytes32 entryId,
        string memory title,
        string memory side,
        address integrator,
        bytes memory clock
    ) internal returns (address entry) {
        BeeefRegistry.PoolConfig memory pool = registry.poolConfig();
        (entry,,,,) = airlock.create(
            BeeefEntryData.build(
                BeeefEntryData.Args({
                    roundId: roundId,
                    entryId: entryId,
                    oracle: oracle,
                    title: title,
                    side: side,
                    integrator: integrator,
                    clock: clock,
                    supply: pool.supply,
                    numeraire: numeraire,
                    tokenFactory: tokenFactory,
                    cloneErc20Factory: tokenFactoryKind == TokenFactoryKind.CloneERC20,
                    governanceFactory: governanceFactory,
                    poolInitializer: poolInitializer,
                    migrator: address(migrator),
                    dopplerHook: dopplerHook,
                    fee: pool.fee,
                    tickSpacing: pool.tickSpacing,
                    curves: pool.curves
                })
            )
        );
        tickSpacingOf[entry] = pool.tickSpacing;
    }

    function _seed(uint256 roundId, address entry, uint256 amountIn, address recipient) internal {
        PoolKey memory key = poolKeyOf(entry);
        // Buying the asset: pay numeraire. zeroForOne when the numeraire is currency0.
        bool zeroForOne = Currency.unwrap(key.currency0) == numeraire;
        bytes memory result = poolManager.unlock(
            abi.encode(SeedCallback({ key: key, zeroForOne: zeroForOne, amountIn: amountIn, recipient: recipient }))
        );
        emit Seeded(roundId, entry, amountIn, abi.decode(result, (uint256)));
    }

    function _round(uint256 roundId) internal view returns (Round storage) {
        require(roundId < _rounds.length, UnknownRound());
        return _rounds[roundId];
    }
}
