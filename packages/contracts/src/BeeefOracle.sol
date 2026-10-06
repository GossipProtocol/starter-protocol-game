// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IAggregatorV3 } from "src/interfaces/IAggregatorV3.sol";
import { IPredictionOracle } from "src/interfaces/IPredictionOracle.sol";
import { IRobinhoodStockToken } from "src/interfaces/IRobinhoodStockToken.sol";

/**
 * @title BeeefOracle
 * @notice Resolves one beeef round: stock A vs stock B, the higher % move from start to end wins.
 * @dev Deployed as an EIP-1167 clone per round, because Doppler's PredictionMigrator keys a market by its oracle
 * address. Prices come from Chainlink push feeds; a round is voided on an exact tie or when a valid snapshot could
 * not be taken inside its window (stale feed, paused feed, sequencer down, or nobody called in time).
 *
 * Snapshot rules (v0):
 * - `snapshotStart()` succeeds once, in `[startTime, startTime + snapshotWindow]`.
 * - `finalize()` in `[endTime, endTime + snapshotWindow]` takes the end snapshot and resolves the round. If the data
 *   is not usable it reverts, so it can be retried inside the window.
 * - `finalize()` after the end window, or at any time after `endTime` when the start snapshot was missed, resolves
 *   the round as void. Both calls are permissionless so users can recover a round when the keeper is down.
 *
 * Void semantics: `getWinner` returns `(entryVoid, true)`. When no VOID entry is registered, `entryVoid` is
 * address(0): the round is finalized, entries can migrate, but PredictionMigrator.claim will revert, so funds stay in
 * the migrator until Doppler ships EVM refunds (strategy A) or a VOID entry is used (strategy B, milestone M6).
 */
contract BeeefOracle is IPredictionOracle {
    uint256 internal constant WAD = 1e18;

    enum Outcome {
        Pending,
        WinnerA,
        WinnerB,
        VoidTie,
        VoidStartMissed,
        VoidEndMissed
    }

    struct Config {
        address feedA;
        address feedB;
        /// @dev Robinhood stock tokens. Used for `uiMultiplier()` and `oraclePaused()`. May be address(0) for feeds
        /// that are not backed by a stock token (tests, crypto pairs); both checks are then skipped.
        address stockA;
        address stockB;
        uint64 startTime;
        uint64 endTime;
        uint32 snapshotWindow;
        /// @dev Max age of a feed answer at snapshot time. Robinhood feeds are 0.5% deviation / 24h heartbeat.
        uint32 maxStaleness;
        /// @dev Chainlink L2 sequencer uptime feed, address(0) to skip.
        address sequencerFeed;
        uint32 sequencerGracePeriod;
        /// @dev Multiply feed answers by the token's uiMultiplier(). Must be false for Robinhood feeds, which already
        /// publish the multiplier-adjusted (total return) token price. True only for raw share-price feeds.
        bool applyMultiplier;
    }

    struct Snapshot {
        int256 priceA;
        int256 priceB;
        uint256 multA;
        uint256 multB;
        uint80 roundIdA;
        uint80 roundIdB;
        uint64 takenAt;
    }

    // ==================== Errors ====================

    error AlreadyInitialized();
    error NotRegistrar();
    error EntriesAlreadySet();
    error InvalidEntries();
    error InvalidConfig();
    error EntriesNotSet();
    error OutsideStartWindow();
    error StartAlreadyTaken();
    error TooEarly();
    error AlreadyFinalized();
    error InvalidAnswer(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error IncompleteRound(address feed);
    error FeedPaused(address stock);
    error SequencerDown();
    error InvalidPresetStart();

    // ==================== Events ====================

    event Initialized(address indexed registrar, Config config);
    event EntriesSet(address entryA, address entryB, address entryVoid);
    event StartCarriedOver(uint64 fromSnapshotAt);
    event StartSnapshot(int256 priceA, int256 priceB, uint256 multA, uint256 multB, uint80 roundIdA, uint80 roundIdB);
    event EndSnapshot(int256 priceA, int256 priceB, uint256 multA, uint256 multB, uint80 roundIdA, uint80 roundIdB);
    event Resolved(Outcome outcome, address winningToken, uint256 moveA, uint256 moveB);

    // ==================== Storage ====================

    Config internal _config;
    address public registrar;

    address public entryA;
    address public entryB;
    address public entryVoid;

    Snapshot internal _start;
    Snapshot internal _end;

    Outcome public outcome;
    address public winner;
    bool public finalized;
    /// @notice Total-return moves in WAD (1e18 = unchanged). Zero until resolved with a valid end snapshot.
    uint256 public moveA;
    uint256 public moveB;

    bool internal _initialized;

    /// @dev Lock the implementation so only clones can be initialized.
    constructor() {
        _initialized = true;
    }

    // ==================== Setup ====================

    /// @notice Called once by the factory right after cloning.
    function initialize(Config calldata cfg, address registrar_) external {
        require(!_initialized, AlreadyInitialized());
        require(
            cfg.feedA != address(0) && cfg.feedB != address(0) && cfg.feedA != cfg.feedB && cfg.endTime > cfg.startTime
                && cfg.snapshotWindow > 0 && cfg.maxStaleness > 0 && registrar_ != address(0),
            InvalidConfig()
        );
        _initialized = true;
        _config = cfg;
        registrar = registrar_;
        emit Initialized(registrar_, cfg);
    }

    /// @notice Registers the Doppler entry tokens. Entries are created after the oracle because Airlock needs the
    /// oracle address in `liquidityMigratorData`.
    function setEntries(address entryA_, address entryB_, address entryVoid_) external {
        require(msg.sender == registrar, NotRegistrar());
        require(entryA == address(0), EntriesAlreadySet());
        require(
            entryA_ != address(0) && entryB_ != address(0) && entryA_ != entryB_ && entryVoid_ != entryA_
                && entryVoid_ != entryB_,
            InvalidEntries()
        );
        entryA = entryA_;
        entryB = entryB_;
        entryVoid = entryVoid_;
        emit EntriesSet(entryA_, entryB_, entryVoid_);
    }

    /// @notice Rolling rounds: the factory seeds this round's start with the previous round's end snapshot, so
    /// consecutive rounds share one price and there is no gap. Only before any start snapshot exists.
    function presetStart(Snapshot calldata s) external {
        require(msg.sender == registrar, NotRegistrar());
        require(_start.takenAt == 0, StartAlreadyTaken());
        require(s.takenAt != 0 && s.priceA > 0 && s.priceB > 0 && s.multA > 0 && s.multB > 0, InvalidPresetStart());
        _start = s;
        emit StartCarriedOver(s.takenAt);
        emit StartSnapshot(s.priceA, s.priceB, s.multA, s.multB, s.roundIdA, s.roundIdB);
    }

    // ==================== Snapshots ====================

    function snapshotStart() external {
        Config memory c = _config;
        require(entryA != address(0), EntriesNotSet());
        require(_start.takenAt == 0, StartAlreadyTaken());
        require(
            block.timestamp >= c.startTime && block.timestamp <= c.startTime + c.snapshotWindow, OutsideStartWindow()
        );

        Snapshot memory s = _takeSnapshot(c);
        _start = s;
        emit StartSnapshot(s.priceA, s.priceB, s.multA, s.multB, s.roundIdA, s.roundIdB);
    }

    function finalize() external {
        Config memory c = _config;
        require(!finalized, AlreadyFinalized());
        require(entryA != address(0), EntriesNotSet());
        require(block.timestamp >= c.endTime, TooEarly());

        if (_start.takenAt == 0) {
            _resolve(Outcome.VoidStartMissed);
            return;
        }
        if (block.timestamp > c.endTime + c.snapshotWindow) {
            _resolve(Outcome.VoidEndMissed);
            return;
        }

        Snapshot memory e = _takeSnapshot(c);
        _end = e;
        emit EndSnapshot(e.priceA, e.priceB, e.multA, e.multB, e.roundIdA, e.roundIdB);

        Snapshot memory s = _start;
        uint256 startA = _adjusted(s.priceA, s.multA, c.applyMultiplier);
        uint256 startB = _adjusted(s.priceB, s.multB, c.applyMultiplier);
        uint256 endA = _adjusted(e.priceA, e.multA, c.applyMultiplier);
        uint256 endB = _adjusted(e.priceB, e.multB, c.applyMultiplier);

        moveA = endA * WAD / startA;
        moveB = endB * WAD / startB;

        // Compare endA/startA vs endB/startB exactly by cross multiplication, so rounding in the WAD moves can never
        // turn a real difference into a tie or vice versa. Realistic operands are < 1e32 each (8-decimal price times a
        // 1e18 multiplier), so the products cannot overflow; an absurd feed answer reverts and the window can retry.
        uint256 lhs = endA * startB;
        uint256 rhs = endB * startA;
        if (lhs > rhs) _resolve(Outcome.WinnerA);
        else if (rhs > lhs) _resolve(Outcome.WinnerB);
        else _resolve(Outcome.VoidTie);
    }

    // ==================== IPredictionOracle ====================

    /// @inheritdoc IPredictionOracle
    /// @dev The `oracle` argument is ignored: every clone is its own market.
    function getWinner(address) external view returns (address winningToken, bool isFinalized) {
        return (winner, finalized);
    }

    // ==================== Views ====================

    function config() external view returns (Config memory) {
        return _config;
    }

    function startSnapshot() external view returns (Snapshot memory) {
        return _start;
    }

    function endSnapshot() external view returns (Snapshot memory) {
        return _end;
    }

    function isVoid() external view returns (bool) {
        return outcome >= Outcome.VoidTie;
    }

    /// @notice True when the round resolved from a valid end snapshot (a winner or an exact tie), i.e. the end
    /// price can be carried over as the next round's start price. False for stale / missed-snapshot voids.
    function hasEndSnapshot() external view returns (bool) {
        return outcome == Outcome.WinnerA || outcome == Outcome.WinnerB || outcome == Outcome.VoidTie;
    }

    // ==================== Internal ====================

    function _resolve(Outcome o) internal {
        outcome = o;
        finalized = true;
        address w = o == Outcome.WinnerA ? entryA : o == Outcome.WinnerB ? entryB : entryVoid;
        winner = w;
        emit Resolved(o, w, moveA, moveB);
        emit WinnerDeclared(address(this), w);
    }

    function _takeSnapshot(Config memory c) internal view returns (Snapshot memory s) {
        _checkSequencer(c);
        (s.priceA, s.roundIdA) = _readFeed(c.feedA, c.maxStaleness);
        (s.priceB, s.roundIdB) = _readFeed(c.feedB, c.maxStaleness);
        s.multA = _readStock(c.stockA);
        s.multB = _readStock(c.stockB);
        s.takenAt = uint64(block.timestamp);
    }

    function _readFeed(address feed, uint32 maxStaleness) internal view returns (int256 answer, uint80 roundId) {
        uint256 updatedAt;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = IAggregatorV3(feed).latestRoundData();
        require(answer > 0, InvalidAnswer(feed));
        require(updatedAt != 0 && answeredInRound >= roundId, IncompleteRound(feed));
        require(
            updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxStaleness, StalePrice(feed, updatedAt)
        );
    }

    /// @dev Returns the token's multiplier (1e18 when there is no stock token) and rejects paused feeds.
    function _readStock(address stock) internal view returns (uint256 mult) {
        if (stock == address(0)) return WAD;
        require(!IRobinhoodStockToken(stock).oraclePaused(), FeedPaused(stock));
        mult = IRobinhoodStockToken(stock).uiMultiplier();
        require(mult > 0, InvalidAnswer(stock));
    }

    function _checkSequencer(Config memory c) internal view {
        if (c.sequencerFeed == address(0)) return;
        (, int256 status, uint256 startedAt,,) = IAggregatorV3(c.sequencerFeed).latestRoundData();
        // 0 = up. startedAt is when the current status began; wait out the grace period after a restart.
        require(status == 0 && startedAt != 0 && block.timestamp - startedAt > c.sequencerGracePeriod, SequencerDown());
    }

    function _adjusted(int256 price, uint256 mult, bool applyMultiplier) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) price > 0 is enforced at snapshot time.
        uint256 p = uint256(price);
        return applyMultiplier ? p * mult : p;
    }
}
