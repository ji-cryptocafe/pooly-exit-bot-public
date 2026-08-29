// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IPrizeVault {
    function maxWithdraw(address owner) external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxShares)
        external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external returns (uint256 assets);
}

/// @title PoolExitor
/// @notice Opportunistically drains a stuck PoolTogether V5 przUSDC position the moment
///         the underlying Moonwell mUSDC market has cash again.
///
/// Why a contract instead of a plain EOA `withdraw()`:
///   The withdrawable amount is set by third-party liquidity and changes every block. An
///   off-chain read is stale by the time the tx lands -- if liquidity fell the tx reverts
///   and you get nothing; if it rose you leave money behind. This reads and executes in
///   the same transaction.
///
/// Security model:
///   - VAULT and ASSET are compile-time constants. Nothing about the target is caller-,
///     deployer-, or governance-supplied.
///   - OWNER, RECEIVER and MIN_RATE_BPS are immutable, fixed at construction.
///   - There is no `call`, `delegatecall`, no setter, no owner role, no sweep, no token
///     parameter anywhere. The only external calls this contract can ever make are to the
///     one hardcoded VAULT address.
///   - `grab()` is therefore permissionless by design: the only assets it can cause to leave
///     OWNER's position are directed to the immutable RECEIVER, at no worse than
///     MIN_RATE_BPS. (It naturally mutates state inside the vault, wmUSDC, Moonwell and the
///     prize pool -- that is the withdrawal itself.) A stranger calling it pays your gas.
///
/// The wallet holding the shares signs exactly one transaction, ever: the ERC20 approve of
/// this contract. It is never needed again, and never needs to be a hot wallet.
contract PoolExitor {
    /// @dev Hardcoded. przUSDC "Prize USDC - Moonwell" on Base.
    IPrizeVault public constant VAULT = IPrizeVault(0x7f5C2b379b88499aC2B997Db583f8079503f25b9);
    /// @dev Hardcoded. Native USDC on Base.
    IERC20 public constant ASSET = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address public immutable OWNER;
    address public immutable RECEIVER;

    /// @notice Worst acceptable redemption rate, in bps of 1 asset per share.
    /// @dev Immutable *on purpose*. This is the slippage floor, and it must not be a call
    ///      parameter: `grab` is permissionless, so a caller-supplied floor would let any
    ///      stranger force the position out at an arbitrarily bad rate. That matters here
    ///      precisely because the premise is a compromised lending market -- if Moonwell
    ///      socialises bad debt, przUSDC becomes lossy and an unbounded exit would realise
    ///      the loss on your behalf. Raising or lowering this requires a redeploy, which is
    ///      a deliberate act by the OWNER.
    uint256 public immutable MIN_RATE_BPS;

    uint256 private constant BPS = 10_000;

    uint256 private _entered;

    error ZeroAddress();
    error BadRate();
    error NothingToGrab(uint256 available, uint256 minAssets);
    error RateFloorBreached(uint256 assets, uint256 sharesRequired);
    error Reentrancy();

    event Grabbed(uint256 assets, uint256 shares, uint256 sharesLeft);

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    /// @param owner_    Wallet holding the przUSDC shares. Must approve this contract once.
    /// @param receiver_ Where recovered USDC is sent. Can be a cold wallet.
    /// @param minRateBps_ Slippage floor. 9999 = accept at most 0.01% below par, which is
    ///        enough to absorb ERC-4626 share rounding while still refusing a real haircut.
    constructor(address owner_, address receiver_, uint256 minRateBps_) {
        if (owner_ == address(0) || receiver_ == address(0)) revert ZeroAddress();
        // Floor must be meaningful: no worse than 50% of par, never better than par.
        if (minRateBps_ > BPS || minRateBps_ < 5_000) revert BadRate();
        OWNER = owner_;
        RECEIVER = receiver_;
        MIN_RATE_BPS = minRateBps_;
    }

    /// @notice Amount currently withdrawable by OWNER. Never reverts.
    /// @dev This, not Moonwell's cash, is the authoritative number: it already folds in
    ///      every conversion layer (USDC -> mUSDC -> wmUSDC -> przUSDC) and PoolTogether
    ///      already rounds it down conservatively.
    function available() public view returns (uint256) {
        try VAULT.maxWithdraw(OWNER) returns (uint256 a) { return a; } catch { return 0; }
    }

    /// @notice Take as much as the vault will currently give up, at no worse than MIN_RATE_BPS.
    /// @param minAssets Fire only if at least this much is obtainable. Evaluated on-chain at
    ///        execution time. This can only ever make the bot *more* conservative: the
    ///        rate floor below is enforced independently of it.
    /// @return assets Amount of underlying sent to RECEIVER.
    function grab(uint256 minAssets) external nonReentrant returns (uint256 assets) {
        uint256 max = available();
        if (max == 0 || max < minAssets) revert NothingToGrab(max, minAssets);

        uint256 shares = VAULT.balanceOf(OWNER);

        // Full exit: redeem by share count so the position closes to exactly zero with no
        // dust left behind (withdrawing by asset amount rounds shares up and can strand a
        // wei, which would keep the bot running forever against an empty position).
        if (VAULT.convertToAssets(shares) <= max) {
            uint256 floor = (shares * MIN_RATE_BPS) / BPS;
            if (floor < minAssets) floor = minAssets;
            assets = VAULT.redeem(shares, RECEIVER, OWNER, floor);
            emit Grabbed(assets, shares, VAULT.balanceOf(OWNER));
            return assets;
        }

        // Partial exit. `withdraw` returns exactly `max` assets by construction, so the
        // slippage that needs bounding is on the share side.
        //
        // No descending retry ladder here: measured over 40 boundary scenarios across both
        // liquidity routes (test/LadderNecessity.t.sol), withdraw(maxWithdraw(owner)) never
        // once failed, because PoolTogether's maxWithdraw already rounds down. A fallback
        // that never fires is not resilience, it is a place for bugs to hide.
        uint256 requiredShares = VAULT.previewWithdraw(max);

        // Rate floor, stated as the invariant rather than reconstructed from a division:
        //     assets / shares >= MIN_RATE_BPS / BPS
        // cross-multiplied, so it is exact and needs no rounding argument.
        // Note the direction: we refuse when the shares demanded are TOO MANY for the
        // assets received. Inverting this comparison rejects healthy exits and waves
        // lossy ones through -- see test_20.
        // previewWithdraw rounds the share cost UP, so requiredShares overstates the true
        // cost by up to 1 wei. Strip that artifact before applying an economic ratio test,
        // otherwise a vault sitting exactly on the floor is rejected by a rounding wei
        // (verified: at rate == MIN_RATE_BPS the un-stripped form reverts -- test_21).
        uint256 ratioShares = requiredShares == 0 ? 0 : requiredShares - 1;
        if (ratioShares * MIN_RATE_BPS > max * BPS) {
            revert RateFloorBreached(max, requiredShares);
        }

        // Belt and braces: hand the vault the exact share count we just priced, so the
        // protocol's own MaxSharesExceeded check catches any divergence between
        // previewWithdraw and the burn path.
        uint256 burned = VAULT.withdraw(max, RECEIVER, OWNER, requiredShares);
        emit Grabbed(max, burned, VAULT.balanceOf(OWNER));
        return max;
    }

    /// @notice Off-chain helper for the bot. Returns 0s instead of reverting when idle.
    function preview() external view returns (uint256 avail, uint256 sharesLeft) {
        return (available(), VAULT.balanceOf(OWNER));
    }
}
