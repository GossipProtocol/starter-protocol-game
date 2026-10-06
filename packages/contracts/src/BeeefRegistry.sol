// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@solady/auth/Ownable.sol";

import { CourseFee } from "src/CourseFee.sol";
import { Curve } from "src/interfaces/IDoppler.sol";
import { BeeefCalendar } from "src/libraries/BeeefCalendar.sol";

/**
 * @title BeeefRegistry
 * @notice Admin configuration read by BeeefRoundFactory: the stock allowlist (token -> Chainlink feed), allowed round
 * lengths, the market calendar, the Doppler pool config, oracle and clock settings, the minimum seed, the platform
 * fee and the course fee. Split out of the factory to keep it under the 24KB contract size limit; it is also what an
 * admin page edits.
 * Changes apply to rounds created afterwards; running rounds keep the settings they were created with.
 */
contract BeeefRegistry is Ownable {
    struct PoolConfig {
        uint24 fee;
        int24 tickSpacing;
        uint256 supply;
        Curve[] curves;
    }

    struct OracleSettings {
        uint32 snapshotWindow;
        uint32 maxStaleness;
        address sequencerFeed;
        uint32 sequencerGracePeriod;
        bool applyMultiplier;
    }

    /// @notice Betting locks `min(lockWindow, duration * lockBps / 10_000)` before the end. The share multiplier falls
    /// linearly from 1.0 at the start to `floorWad` at the lock.
    struct ClockSettings {
        uint32 lockWindow;
        uint16 lockBps;
        uint64 floorWad;
    }

    struct Stock {
        address feed;
        string symbol;
    }

    error InvalidPoolConfig();
    error InvalidClockSettings();
    error InvalidWeeklyClose();
    error InvalidPlatformFee();

    event StockSet(address indexed stock, address feed, string symbol);
    event DurationSet(uint256 duration, bool allowed);
    event ClosedDaySet(uint256 indexed day, bool closed);
    event WeeklyCloseSet(uint32 start, uint32 end);
    event PoolConfigSet(uint24 fee, int24 tickSpacing, uint256 supply);
    event OracleSettingsSet(OracleSettings settings);
    event ClockSettingsSet(ClockSettings settings);
    event MinSeedSet(uint256 minSeed);
    event PlatformFeeSet(address recipient, uint16 bps);

    PoolConfig internal _poolConfig;
    OracleSettings internal _oracleSettings;
    ClockSettings internal _clockSettings;
    mapping(address stock => Stock) internal _stocks;

    mapping(uint256 duration => bool) public allowedDuration;
    /// @notice UTC day index (timestamp / 1 days) => market holiday.
    mapping(uint256 day => bool) public closedDay;
    /// @notice Weekly closed window in seconds from Sunday 00:00 UTC. Wraps when end < start.
    uint32 public weeklyCloseStart;
    uint32 public weeklyCloseEnd;
    /// @notice Minimum seed per side of a round.
    uint256 public minSeed;
    /// @notice Platform cut of every series' integrator fees, applied by its fee splitter after the course fee.
    address public platformFeeRecipient;
    uint16 public platformFeeBps;
    /// @notice Platform fee plus course fee may not exceed this.
    uint16 public constant MAX_TOTAL_FEE_BPS = 2000;

    constructor(
        address owner_,
        PoolConfig memory pool,
        OracleSettings memory oracleSettings_,
        ClockSettings memory clockSettings_,
        uint256 minSeed_
    ) {
        _initializeOwner(owner_);
        _setPoolConfig(pool);
        _oracleSettings = oracleSettings_;
        emit OracleSettingsSet(oracleSettings_);
        _setClockSettings(clockSettings_);
        minSeed = minSeed_;
        emit MinSeedSet(minSeed_);

        // 24/5 equity feeds: closed from Friday 20:00 ET to Sunday 20:00 ET. Conservative in UTC across DST:
        // Saturday 00:00 UTC to Monday 01:00 UTC.
        _setWeeklyClose(6 days, 1 days + 1 hours);
        _setDuration(10 minutes, true);
        _setDuration(30 minutes, true);
        _setDuration(1 hours, true);
        _setDuration(1 days, true);
    }

    // ==================== Views ====================

    function stock(address stockToken) external view returns (Stock memory) {
        return _stocks[stockToken];
    }

    function poolConfig() external view returns (PoolConfig memory) {
        return _poolConfig;
    }

    function oracleSettings() external view returns (OracleSettings memory) {
        return _oracleSettings;
    }

    function clockSettings() external view returns (ClockSettings memory) {
        return _clockSettings;
    }

    /// @notice Lock time for a round `[start, start + duration]`.
    function lockTimeFor(uint256 start, uint256 duration) external view returns (uint64) {
        ClockSettings memory c = _clockSettings;
        uint256 byPct = duration * c.lockBps / 10_000;
        uint256 lockLen = byPct < c.lockWindow ? byPct : c.lockWindow;
        return uint64(start + duration - lockLen);
    }

    /// @notice False if `[start, end]` overlaps the weekly close or a UTC day flagged as a holiday.
    function isMarketOpen(uint256 start, uint256 end) external view returns (bool) {
        return BeeefCalendar.isMarketOpen(closedDay, weeklyCloseStart, weeklyCloseEnd, start, end);
    }

    /// @notice Earliest time `>= t` at which a round of `duration` (plus its end snapshot window) fits the session.
    function nextStart(uint256 t, uint256 duration) external view returns (uint64) {
        return BeeefCalendar.nextStart(
            closedDay, weeklyCloseStart, weeklyCloseEnd, t, duration + _oracleSettings.snapshotWindow
        );
    }

    /// @notice The course fee every series' splitter pays before the platform cut. Fixed in `CourseFee.sol`.
    function courseFee() external pure returns (address recipient, uint16 bps) {
        return (CourseFee.COURSE_FEE_RECIPIENT, CourseFee.COURSE_FEE_BPS);
    }

    /// @notice False while `CourseFee.COURSE_FEE_RECIPIENT` is still the zero placeholder. Deploy scripts check this.
    function courseFeeConfigured() external pure returns (bool) {
        return CourseFee.configured();
    }

    // ==================== Admin ====================

    function setStock(address stockToken, address feed, string calldata symbol) external onlyOwner {
        _stocks[stockToken] = Stock({ feed: feed, symbol: symbol });
        emit StockSet(stockToken, feed, symbol);
    }

    function setDuration(uint256 duration, bool allowed) external onlyOwner {
        _setDuration(duration, allowed);
    }

    function setClosedDay(uint256 day, bool closed) external onlyOwner {
        closedDay[day] = closed;
        emit ClosedDaySet(day, closed);
    }

    function setWeeklyClose(uint32 start, uint32 end) external onlyOwner {
        _setWeeklyClose(start, end);
    }

    function setPoolConfig(PoolConfig calldata pool) external onlyOwner {
        _setPoolConfig(pool);
    }

    function setOracleSettings(OracleSettings calldata s) external onlyOwner {
        _oracleSettings = s;
        emit OracleSettingsSet(s);
    }

    function setClockSettings(ClockSettings calldata c) external onlyOwner {
        _setClockSettings(c);
    }

    function setMinSeed(uint256 minSeed_) external onlyOwner {
        minSeed = minSeed_;
        emit MinSeedSet(minSeed_);
    }

    /// @notice Platform cut of integrator fees for series created from now on. Platform plus course fee stay at or
    /// below `MAX_TOTAL_FEE_BPS`.
    function setPlatformFee(address recipient, uint16 bps) external onlyOwner {
        require(
            uint256(bps) + CourseFee.COURSE_FEE_BPS <= MAX_TOTAL_FEE_BPS && (bps == 0 || recipient != address(0)),
            InvalidPlatformFee()
        );
        platformFeeRecipient = recipient;
        platformFeeBps = bps;
        emit PlatformFeeSet(recipient, bps);
    }

    // ==================== Internal ====================

    function _setPoolConfig(PoolConfig memory pool) internal {
        require(pool.fee > 0 && pool.fee <= 100_000 && pool.supply > 0 && pool.curves.length > 0, InvalidPoolConfig());
        delete _poolConfig.curves;
        _poolConfig.fee = pool.fee;
        _poolConfig.tickSpacing = pool.tickSpacing;
        _poolConfig.supply = pool.supply;
        for (uint256 i; i < pool.curves.length; ++i) {
            _poolConfig.curves.push(pool.curves[i]);
        }
        emit PoolConfigSet(pool.fee, pool.tickSpacing, pool.supply);
    }

    function _setClockSettings(ClockSettings memory c) internal {
        require(c.floorWad > 0 && c.floorWad <= 1e18 && c.lockBps <= 10_000 && c.lockWindow > 0, InvalidClockSettings());
        _clockSettings = c;
        emit ClockSettingsSet(c);
    }

    function _setDuration(uint256 duration, bool allowed) internal {
        allowedDuration[duration] = allowed;
        emit DurationSet(duration, allowed);
    }

    function _setWeeklyClose(uint32 start, uint32 end) internal {
        require(start < 1 weeks && end < 1 weeks && start != end, InvalidWeeklyClose());
        weeklyCloseStart = start;
        weeklyCloseEnd = end;
        emit WeeklyCloseSet(start, end);
    }
}
