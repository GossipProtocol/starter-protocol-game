// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { BeeefRoundFlow } from "test/utils/BeeefRoundFlow.sol";
import { LocalDopplerSetup } from "test/utils/LocalDopplerSetup.sol";

/// @notice Full round against a fresh local Doppler deployment (the pinned `lib/doppler` submodule).
contract BeeefRoundLocalTest is LocalDopplerSetup, BeeefRoundFlow { }
