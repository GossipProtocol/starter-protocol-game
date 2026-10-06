// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { SafeTransferLib } from "@solady/utils/SafeTransferLib.sol";

import { CourseFee } from "src/CourseFee.sol";
import { IAirlock } from "src/interfaces/IDoppler.sol";

/**
 * @title BeeefFeeSplitter
 * @notice One clone per series. It is the Airlock `integrator` for every round in the series, so the integrator share
 * of each round's LP fees accrues to it at migration. `collect` pulls those fees out of Airlock and `distribute` pays
 * them out: first the course fee (see `CourseFee`), then the platform cut, then the creator's recipients by their
 * fixed bps. Both are permissionless.
 */
contract BeeefFeeSplitter {
    using SafeTransferLib for address;

    uint256 public constant MAX_RECIPIENTS = 5;

    error AlreadyInitialized();
    error InvalidSplit();

    event Collected(address indexed token, uint256 amount);
    event Distributed(address indexed token, address indexed recipient, uint256 amount);

    IAirlock public airlock;
    address public platform;
    uint16 public platformBps;
    address[] internal _recipients;
    uint16[] internal _bps;
    bool internal _initialized;

    constructor() {
        _initialized = true;
    }

    /// @param bps_ Shares of what is left after the platform cut; must sum to 10_000.
    function initialize(
        IAirlock airlock_,
        address platform_,
        uint16 platformBps_,
        address[] calldata recipients_,
        uint16[] calldata bps_
    ) external {
        require(!_initialized, AlreadyInitialized());
        _initialized = true;
        require(
            recipients_.length > 0 && recipients_.length <= MAX_RECIPIENTS && recipients_.length == bps_.length
                && platformBps_ <= 10_000 && (platformBps_ == 0 || platform_ != address(0)),
            InvalidSplit()
        );
        uint256 sum;
        for (uint256 i; i < bps_.length; ++i) {
            require(recipients_[i] != address(0) && bps_[i] > 0, InvalidSplit());
            sum += bps_[i];
        }
        require(sum == 10_000, InvalidSplit());
        airlock = airlock_;
        platform = platform_;
        platformBps = platformBps_;
        _recipients = recipients_;
        _bps = bps_;
    }

    /// @notice Pulls this splitter's integrator fees for `token` out of Airlock.
    function collect(address token) public returns (uint256 amount) {
        amount = airlock.getIntegratorFees(address(this), token);
        if (amount > 0) {
            airlock.collectIntegratorFees(address(this), token, amount);
            emit Collected(token, amount);
        }
    }

    /// @notice Splits this contract's whole `token` balance: course fee, platform cut, then the creator's recipients.
    /// The last recipient takes the rounding remainder.
    function distribute(address token) public {
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        if (balance == 0) return;
        uint256 courseCut = CourseFee.cut(balance);
        if (courseCut > 0) {
            token.safeTransfer(CourseFee.COURSE_FEE_RECIPIENT, courseCut);
            emit Distributed(token, CourseFee.COURSE_FEE_RECIPIENT, courseCut);
            balance -= courseCut;
        }
        uint256 platformCut = balance * platformBps / 10_000;
        if (platformCut > 0) {
            token.safeTransfer(platform, platformCut);
            emit Distributed(token, platform, platformCut);
        }
        uint256 rest = balance - platformCut;
        uint256 paid;
        uint256 n = _recipients.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = i == n - 1 ? rest - paid : rest * _bps[i] / 10_000;
            paid += amount;
            if (amount > 0) {
                token.safeTransfer(_recipients[i], amount);
                emit Distributed(token, _recipients[i], amount);
            }
        }
    }

    function collectAndDistribute(address token) external {
        collect(token);
        distribute(token);
    }

    function recipients() external view returns (address[] memory, uint16[] memory) {
        return (_recipients, _bps);
    }
}
