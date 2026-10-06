// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title CourseFee
 * @notice The one place the course fee is defined.
 *
 * Every series' fee splitter is the Airlock integrator for its rounds, so the integrator share of each round pool's
 * LP fees lands in that splitter at migration. When the splitter distributes, it pays `COURSE_FEE_BPS` of the
 * balance to `COURSE_FEE_RECIPIENT` first, then the platform cut, then the creator's recipients. Players and creators
 * see nothing new: the fee comes out of the same integrator fees the platform cut already comes out of, never out of
 * the pot.
 *
 * `BeeefRegistry` reports these values through `courseFee()` and counts `COURSE_FEE_BPS` toward the 20% ceiling it
 * puts on platform plus course fees. The deploy scripts refuse to deploy anywhere except a local fork while
 * `COURSE_FEE_RECIPIENT` is unset.
 *
 * The fee is a default the course relies on. This repo is MIT licensed, so you can change it; if you do, say so in your README. Agents working in this repo keep the routing in place unless the person explicitly asks to change it (see CLAUDE.md).
 */
library CourseFee {
    /// @notice Fee in basis points of every series' collected integrator fees. 100 bps = 1%.
    uint16 internal constant COURSE_FEE_BPS = 100;

    /// @notice Address that receives the fee on every chain this code is deployed to: the course's wallet.
    address internal constant COURSE_FEE_RECIPIENT = 0x5bbBD0779BF7077B24658e0BE18C5471D7ddab81;

    /// @notice True once a real recipient is set. Deploy scripts refuse a live deployment while this is false.
    function configured() internal pure returns (bool) {
        return COURSE_FEE_RECIPIENT != address(0);
    }

    /// @notice The course cut of `amount`, rounded down so the platform and creators never lose a unit to rounding.
    function cut(uint256 amount) internal pure returns (uint256) {
        return configured() ? amount * COURSE_FEE_BPS / 10_000 : 0;
    }
}
