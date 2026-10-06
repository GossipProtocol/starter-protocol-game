// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal, ABI-compatible declarations of the Doppler contracts beeef calls. Doppler is BUSL-1.1, so
/// `src/` redeclares only the ABI it needs instead of importing the source. Contract-typed struct fields upstream
/// are `address` here; the ABI encoding is identical.

struct CreateParams {
    uint256 initialSupply;
    uint256 numTokensToSell;
    address numeraire;
    address tokenFactory;
    bytes tokenFactoryData;
    address governanceFactory;
    bytes governanceFactoryData;
    address poolInitializer;
    bytes poolInitializerData;
    address liquidityMigrator;
    bytes liquidityMigratorData;
    address integrator;
    bytes32 salt;
}

/// @dev DopplerHookInitializer curve (src/libraries/Multicurve.sol).
struct Curve {
    int24 tickLower;
    int24 tickUpper;
    uint16 numPositions;
    uint256 shares;
}

struct BeneficiaryData {
    address beneficiary;
    uint96 shares;
}

/// @dev DopplerHookInitializer InitData. Field order matters for abi.encode.
struct InitData {
    uint24 fee;
    int24 tickSpacing;
    int24 farTick;
    Curve[] curves;
    BeneficiaryData[] beneficiaries;
    address dopplerHook;
    bytes onInitializationDopplerHookCalldata;
    bytes graduationDopplerHookCalldata;
}

interface IAirlock {
    function create(CreateParams calldata createData)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool);

    function migrate(address asset) external;

    function owner() external view returns (address);

    function getIntegratorFees(address integrator, address token) external view returns (uint256);

    function collectIntegratorFees(address to, address token, uint256 amount) external;
}

interface IPredictionMigrator {
    struct MarketView {
        uint256 totalPot;
        uint256 totalClaimed;
        address winningToken;
        address numeraire;
        bool isResolved;
    }

    struct EntryView {
        address token;
        address oracle;
        bytes32 entryId;
        uint256 contribution;
        uint256 claimableSupply;
        bool isMigrated;
    }

    function claim(address oracle, uint256 tokenAmount) external;

    function previewClaim(address oracle, uint256 tokenAmount) external view returns (uint256);

    function getMarket(address oracle) external view returns (MarketView memory);

    function getEntry(address oracle, bytes32 entryId) external view returns (EntryView memory);

    function getEntryByToken(address oracle, address token) external view returns (EntryView memory);
}
