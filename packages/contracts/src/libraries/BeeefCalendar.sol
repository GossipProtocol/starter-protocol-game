// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title BeeefCalendar
 * @notice Market-hours maths for BeeefRoundFactory, as a linked library to keep the factory under the 24KB code limit.
 * A weekly closed window (seconds from Sunday 00:00 UTC, wrapping when end < start) plus UTC-day holidays.
 * Mirrored in packages/sdk/src/calendar.ts and checked by SdkVectors.
 */
library BeeefCalendar {
    /// @notice False if `[start, end]` overlaps the weekly close or a holiday.
    function isMarketOpen(
        mapping(uint256 day => bool) storage closedDay,
        uint32 closeStart_,
        uint32 closeEnd_,
        uint256 start,
        uint256 end
    ) internal view returns (bool) {
        return _blockedUntil(closedDay, closeStart_, closeEnd_, start, end) == 0;
    }

    /// @notice Earliest time `>= t` at which `[t, t + span]` is open.
    function nextStart(
        mapping(uint256 day => bool) storage closedDay,
        uint32 closeStart_,
        uint32 closeEnd_,
        uint256 t,
        uint256 span
    ) internal view returns (uint64) {
        for (uint256 i; i < 32; ++i) {
            uint256 until = _blockedUntil(closedDay, closeStart_, closeEnd_, t, t + span);
            if (until == 0) return uint64(t);
            t = until;
        }
        revert("market closed");
    }

    /// @dev 0 when `[start, end]` is open, otherwise the end of the first holiday or weekly close blocking it.
    function _blockedUntil(
        mapping(uint256 day => bool) storage closedDay,
        uint32 closeStart_,
        uint32 closeEnd_,
        uint256 start,
        uint256 end
    ) private view returns (uint256) {
        for (uint256 day = start / 1 days; day <= end / 1 days; ++day) {
            if (closedDay[day]) return (day + 1) * 1 days;
        }
        // 1970-01-01 was a Thursday, so day 3 is the first Sunday.
        uint256 weekStart = start - ((start / 1 days + 4) % 7) * 1 days - (start % 1 days);
        uint256 closeLen = closeEnd_ > closeStart_ ? closeEnd_ - closeStart_ : 1 weeks - closeStart_ + closeEnd_;
        // A wrapping window that started last week can still cover `start`; check last, this and next week.
        for (uint256 i; i < 3; ++i) {
            if (weekStart + i * 1 weeks < 1 weeks) continue;
            uint256 closeStart = weekStart + i * 1 weeks - 1 weeks + closeStart_;
            if (start < closeStart + closeLen && closeStart < end) return closeStart + closeLen;
        }
        return 0;
    }
}
