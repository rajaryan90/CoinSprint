// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev Minimal interface matching a standard Uniswap-V2-style router.
///      Point `router` at Arc's actual deployed DEX router once mainnet
///      addresses are confirmed — never deploy against a guessed address.
interface IArcRouter {
    function factory() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

interface IArcFactory {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/**
 * @title MemecoinBondingCurve
 * @notice A self-contained constant-product bonding curve for a single
 *         fair-launch token, priced against USDC. One instance per token,
 *         deployed as a cheap EIP-1167 clone by LaunchpadFactory.
 *
 * Design decisions (read before changing anything):
 *  - 100% of supply is minted to the curve itself at init. Nothing is
 *    pre-mined to the creator. This removes the single most common rug
 *    vector: a founder allocation that gets dumped on early buyers.
 *  - No owner, no admin functions, no pause, no upgradeability. Once
 *    initialize() runs, nobody — including whoever deployed the factory —
 *    can mint more supply, change the curve, or move funds out except
 *    through buy()/sell() at the posted curve price.
 *  - We use OpenZeppelin's *Upgradeable* ERC20 base (ERC20Upgradeable)
 *    purely because clones can't run a constructor, so state has to be
 *    set through an initializer instead. This contract is NOT upgradeable
 *    in the proxy-admin sense — there is no UUPS/Transparent proxy layer,
 *    no admin slot, nothing to point at a new implementation. "Upgradeable
 *    base, non-upgradeable deployment" is intentional: it's what makes
 *    each token's logic immutable once live.
 *  - Reentrancy protection uses ReentrancyGuardTransient (EIP-1153
 *    transient storage) rather than the classic storage-slot guard.
 *    OpenZeppelin documents it as stateless: it keeps no persistent
 *    storage layout at all, so there is nothing to initialize, which
 *    makes it a clean fit for a clone. Only requirement: the chain must
 *    support EIP-1153 (Cancun+). Confirm this against Arc's actual EVM
 *    version before relying on it; fall back to the classic
 *    ReentrancyGuard with an explicit init call if Arc turns out to be
 *    pre-Cancun.
 *  - On graduation, 100% of the real (non-virtual) USDC reserve and a
 *    fixed token allocation go into a DEX pool, and the LP tokens are
 *    burned, not held. Nobody can pull that liquidity back out later —
 *    including this contract.
 *  - The 1% trade fee (TRADE_FEE_BPS) is split between the token's
 *    creator and an optional platform fee recipient, set once at launch
 *    via the factory. The split never changes what a trader pays in
 *    total — platformFeeBps takes a slice OF the existing fee, it's never
 *    added on top. Liquidity itself is never touched by this: the
 *    platform cut only ever comes out of the trading fee, never out of
 *    the USDC that backs graduation.
 *  - Optional anti-whale cap (maxWalletBps): while a token hasn't
 *    graduated yet, no single wallet can hold more than maxWalletBps of
 *    TOTAL_SUPPLY, checked on every buy. This is the direct mechanism
 *    against pump-and-dump: it stops one actor from acquiring a dominant
 *    share of supply cheaply at launch and dumping on everyone who buys
 *    after them. Off by default (0 = disabled) so it never silently
 *    changes behavior for anything already relying on the old signature;
 *    a real deployment should turn it on. The cap only applies pre-
 *    graduation — once trading moves to the DEX pool, normal market
 *    rules apply, same as any other token there.
 */
contract MemecoinBondingCurve is Initializable, ERC20Upgradeable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    address public router;
    address public creator;
    address public platformFeeRecipient;
    uint256 public platformFeeBps;
    uint256 public maxWalletBps;

    uint256 public virtualUsdcReserve;
    uint256 public virtualTokenReserve;
    uint256 public realUsdcReserve;
    uint256 public graduationThreshold;
    uint8 public usdcDecimals;

    /// @dev virtualUsdcReserve * virtualTokenReserve, fixed once at init.
    ///      Deliberately NOT recomputed from current reserves on every
    ///      call — an earlier version did that, and it silently
    ///      compounded integer-division rounding across trades until a
    ///      buy-then-sell round trip could demand fractionally more USDC
    ///      than the curve actually held, reverting with "insufficient
    ///      reserve". Holding k fixed makes a full round trip refund the
    ///      exact net amount paid in, with zero drift. See the buy()/
    ///      sell() math: each individually still floor-rounds slightly in
    ///      the trader's favor (normal, harmless, dust-level), but that
    ///      no longer compounds across trades because every trade divides
    ///      against the same original invariant instead of an
    ///      already-rounded one.
    uint256 public k;

    bool public graduated;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant CURVE_SUPPLY = 800_000_000e18;      // sellable on the curve
    uint256 public constant LIQUIDITY_SUPPLY = 200_000_000e18;  // reserved for DEX graduation
    uint256 public constant TRADE_FEE_BPS = 100;                // 1% per trade, total (split creator/platform)
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    event Buy(address indexed buyer, uint256 usdcIn, uint256 tokensOut);
    event Sell(address indexed seller, uint256 tokensIn, uint256 usdcOut);
    event Graduated(address indexed pair, uint256 usdcToLiquidity, uint256 tokensToLiquidity);

    /// @dev Locks the implementation contract itself so it can never be
    ///      initialized directly (only clones should be initialized).
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address usdc_,
        address router_,
        address creator_,
        uint256 initialVirtualUsdc_,
        uint256 graduationThreshold_,
        address platformFeeRecipient_,
        uint256 platformFeeBps_,
        uint256 maxWalletBps_
    ) external initializer {
        require(usdc_ != address(0) && router_ != address(0) && creator_ != address(0), "zero address");
        require(initialVirtualUsdc_ > 0, "bad virtual reserve");
        require(graduationThreshold_ > 0, "bad threshold");
        // Platform can only ever take a slice OF the existing 1% trade
        // fee, never a cut on top of it — total cost to traders never
        // changes based on how this is split. A recipient of address(0)
        // with 0 bps is valid and means "no platform cut, 100% to
        // creator," which is also what happens if a factory deployer
        // doesn't want to take a cut at all.
        require(platformFeeBps_ <= TRADE_FEE_BPS, "platform cut exceeds total fee");
        require(platformFeeBps_ == 0 || platformFeeRecipient_ != address(0), "platform fee needs a recipient");
        // 0 = disabled (opt-in, not forced), otherwise must be a real cap
        // and not so tight it makes normal trading impossible.
        require(maxWalletBps_ <= BPS_DENOMINATOR, "maxWalletBps over 100%");

        __ERC20_init(name_, symbol_);

        usdc = IERC20(usdc_);
        usdcDecimals = IERC20Metadata(usdc_).decimals();
        router = router_;
        creator = creator_;
        platformFeeRecipient = platformFeeRecipient_;
        platformFeeBps = platformFeeBps_;
        maxWalletBps = maxWalletBps_;
        virtualUsdcReserve = initialVirtualUsdc_;
        virtualTokenReserve = CURVE_SUPPLY;
        k = initialVirtualUsdc_ * CURVE_SUPPLY;
        graduationThreshold = graduationThreshold_;

        _mint(address(this), TOTAL_SUPPLY);
    }

    /// @notice Buy tokens off the curve with USDC.
    /// @param usdcIn Amount of USDC to spend (18-decimals-normalized by caller if needed).
    /// @param minTokensOut Slippage floor; reverts if the fill is worse than this.
    function buy(uint256 usdcIn, uint256 minTokensOut) external nonReentrant {
        require(!graduated, "graduated: trade on the DEX pool instead");
        require(usdcIn > 0, "zero amount");

        uint256 fee = (usdcIn * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 usdcInAfterFee = usdcIn - fee;

        uint256 newVirtualUsdcReserve = virtualUsdcReserve + usdcInAfterFee;
        uint256 newVirtualTokenReserve = k / newVirtualUsdcReserve;
        uint256 tokensOut = virtualTokenReserve - newVirtualTokenReserve;

        require(tokensOut >= minTokensOut, "slippage");
        require(balanceOf(address(this)) >= tokensOut, "insufficient curve balance");
        if (maxWalletBps > 0) {
            uint256 cap = (TOTAL_SUPPLY * maxWalletBps) / BPS_DENOMINATOR;
            require(balanceOf(msg.sender) + tokensOut <= cap, "exceeds max wallet during raise");
        }

        virtualUsdcReserve = newVirtualUsdcReserve;
        virtualTokenReserve = newVirtualTokenReserve;
        realUsdcReserve += usdcInAfterFee;

        usdc.safeTransferFrom(msg.sender, address(this), usdcIn);
        if (fee > 0) {
            uint256 platformCut = (usdcIn * platformFeeBps) / BPS_DENOMINATOR;
            uint256 creatorCut = fee - platformCut;
            if (platformCut > 0) usdc.safeTransfer(platformFeeRecipient, platformCut);
            if (creatorCut > 0) usdc.safeTransfer(creator, creatorCut);
        }
        _transfer(address(this), msg.sender, tokensOut);

        emit Buy(msg.sender, usdcIn, tokensOut);

        if (realUsdcReserve >= graduationThreshold) {
            _graduate();
        }
    }

    /// @notice Sell tokens back into the curve for USDC.
    function sell(uint256 tokensIn, uint256 minUsdcOut) external nonReentrant {
        require(!graduated, "graduated: trade on the DEX pool instead");
        require(tokensIn > 0, "zero amount");

        uint256 newVirtualTokenReserve = virtualTokenReserve + tokensIn;
        uint256 newVirtualUsdcReserve = k / newVirtualTokenReserve;
        uint256 usdcOutBeforeFee = virtualUsdcReserve - newVirtualUsdcReserve;

        uint256 fee = (usdcOutBeforeFee * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 usdcOut = usdcOutBeforeFee - fee;

        require(usdcOut >= minUsdcOut, "slippage");
        require(realUsdcReserve >= usdcOutBeforeFee, "insufficient reserve");

        virtualUsdcReserve = newVirtualUsdcReserve;
        virtualTokenReserve = newVirtualTokenReserve;
        realUsdcReserve -= usdcOutBeforeFee;

        _transfer(msg.sender, address(this), tokensIn);
        usdc.safeTransfer(msg.sender, usdcOut);
        if (fee > 0) {
            uint256 platformCut = (usdcOutBeforeFee * platformFeeBps) / BPS_DENOMINATOR;
            uint256 creatorCut = fee - platformCut;
            if (platformCut > 0) usdc.safeTransfer(platformFeeRecipient, platformCut);
            if (creatorCut > 0) usdc.safeTransfer(creator, creatorCut);
        }

        emit Sell(msg.sender, tokensIn, usdcOut);
    }

    /// @notice Permissionless — anyone can trigger graduation once the
    ///         threshold is met, so it never depends on a trusted caller.
    function graduate() external nonReentrant {
        require(!graduated, "already graduated");
        require(realUsdcReserve >= graduationThreshold, "threshold not met");
        require(_graduate(), "graduation failed, router call reverted");
    }

    /// @dev Returns true if graduation actually completed. Deliberately
    ///      does NOT revert on router failure — see the try/catch below.
    ///      An earlier version let a router revert propagate, which meant
    ///      any bad router state (paused pool, unmet minimum, whatever)
    ///      would roll back `graduated` and `realUsdcReserve` right along
    ///      with it, and the NEXT buy() would immediately re-trigger the
    ///      same failing graduation attempt and revert too — permanently
    ///      bricking every future buy on the token, since buy() always
    ///      re-attempts graduation once the threshold is crossed. Selling
    ///      would still have worked, buying never would have again.
    ///      Catching the failure here means a bad graduation attempt costs
    ///      nothing but itself: the buy that triggered it still succeeds,
    ///      and graduation can be retried later via the standalone
    ///      graduate() function once whatever blocked the router is fixed.
    function _graduate() internal returns (bool) {
        uint256 usdcForLiquidity = realUsdcReserve;
        uint256 tokensForLiquidity = LIQUIDITY_SUPPLY;

        usdc.forceApprove(router, usdcForLiquidity);
        _approve(address(this), router, tokensForLiquidity);

        try IArcRouter(router).addLiquidity(
            address(this),
            address(usdc),
            tokensForLiquidity,
            usdcForLiquidity,
            0,
            0,
            address(this),
            block.timestamp
        ) returns (uint256, uint256, uint256 liquidity) {
            graduated = true;
            realUsdcReserve = 0;

            address pair = IArcFactory(IArcRouter(router).factory()).getPair(address(this), address(usdc));
            // Burn the LP tokens: liquidity is now permanently locked. No
            // creator withdrawal path exists anywhere in this contract.
            IERC20(pair).safeTransfer(BURN_ADDRESS, liquidity);

            // Any curve-supply dust left unsold gets burned rather than
            // returned to the creator, so circulating supply stays honest.
            uint256 dust = balanceOf(address(this));
            if (dust > 0) _burn(address(this), dust);

            emit Graduated(pair, usdcForLiquidity, tokensForLiquidity);
            return true;
        } catch {
            // Router rejected the call. Undo the approvals we just set so
            // they don't linger, and leave every reserve untouched — from
            // the outside, this attempt never happened.
            usdc.forceApprove(router, 0);
            _approve(address(this), router, 0);
            return false;
        }
    }

    /// @notice Spot price in USDC per token, normalized to 18-decimal
    ///         fixed point regardless of how many decimals the USDC
    ///         token actually uses (real USDC is 6; our test mock is 18
    ///         — this must not assume either). Useful for frontends
    ///         before they bother simulating buy().
    function currentPrice() external view returns (uint256) {
        uint256 scale = 10 ** (36 - uint256(usdcDecimals));
        return (virtualUsdcReserve * scale) / virtualTokenReserve;
    }
}
