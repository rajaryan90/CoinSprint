// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "./MemecoinBondingCurve.sol";

/**
 * @title LaunchpadFactory
 * @notice Deploys gas-cheap EIP-1167 clones of MemecoinBondingCurve.
 *
 * Deliberately has NO admin functions over tokens it has already
 * deployed — it can create new ones, and that's it. Two consequences:
 *  - There is no single key whose compromise puts every launched token
 *    at risk. A bug or attack against the factory can affect future
 *    deployments, never past ones.
 *  - Changing default parameters (e.g. graduation threshold) means
 *    deploying a new factory, not upgrading this one. That's a feature:
 *    it means a parameter change can never retroactively alter a token
 *    that's already live.
 */
contract LaunchpadFactory {
    address public immutable implementation;
    address public immutable usdc;
    address public immutable router;
    uint256 public immutable defaultInitialVirtualUsdc;
    uint256 public immutable defaultGraduationThreshold;
    address public immutable platformFeeRecipient;
    uint256 public immutable platformFeeBps;
    uint256 public immutable defaultMaxWalletBps;

    address[] public allTokens;

    event TokenLaunched(address indexed token, address indexed creator, string name, string symbol);

    /// @param usdc_ Arc's USDC token address.
    /// @param router_ Arc's DEX router address (e.g. the Uniswap-V2-style
    ///        router once confirmed live on Arc) — see MemecoinBondingCurve
    ///        for why this must not be guessed.
    /// @param defaultInitialVirtualUsdc_ Virtual USDC reserve new tokens
    ///        start with; controls how steep the early curve is.
    /// @param defaultGraduationThreshold_ Real USDC raised at which a
    ///        token graduates to a DEX pool.
    /// @param platformFeeRecipient_ Where the platform's slice of the 1%
    ///        trade fee goes on every token this factory creates. Pass
    ///        address(0) with platformFeeBps_ = 0 to take no cut at all —
    ///        every launched token is then 100% creator-fee, same as
    ///        before this feature existed.
    /// @param platformFeeBps_ Platform's slice of the fixed 1% trade fee,
    ///        in basis points of the trade (not of the fee) — e.g. 20
    ///        means 0.2% to platform, 0.8% to creator, trader still only
    ///        ever pays 1% total. Immutable, same reasoning as everything
    ///        else here: changing it means a new factory, not a flag flip
    ///        that could retroactively touch tokens already live.
    /// @param defaultMaxWalletBps_ Anti-whale cap applied to every token
    ///        this factory creates, in bps of TOTAL_SUPPLY a single wallet
    ///        may hold pre-graduation. 0 disables it. See
    ///        MemecoinBondingCurve for the full reasoning.
    constructor(
        address usdc_,
        address router_,
        uint256 defaultInitialVirtualUsdc_,
        uint256 defaultGraduationThreshold_,
        address platformFeeRecipient_,
        uint256 platformFeeBps_,
        uint256 defaultMaxWalletBps_
    ) {
        require(usdc_ != address(0) && router_ != address(0), "zero address");
        require(platformFeeBps_ <= 100, "platform cut exceeds the fixed 1% total fee");
        // Same check MemecoinBondingCurve.initialize() enforces per-token —
        // duplicated here so a bad combination fails at factory deploy
        // time, loudly, instead of deploying a factory that looks fine
        // but silently reverts on every single createToken() call because
        // the underlying initialize() rejects it every time. Slither's
        // missing-zero-check flagged the absence of this; it was right to.
        require(platformFeeBps_ == 0 || platformFeeRecipient_ != address(0), "platform fee needs a recipient");
        require(defaultMaxWalletBps_ <= 10_000, "defaultMaxWalletBps over 100%");
        implementation = address(new MemecoinBondingCurve());
        usdc = usdc_;
        router = router_;
        defaultInitialVirtualUsdc = defaultInitialVirtualUsdc_;
        defaultGraduationThreshold = defaultGraduationThreshold_;
        platformFeeRecipient = platformFeeRecipient_;
        platformFeeBps = platformFeeBps_;
        defaultMaxWalletBps = defaultMaxWalletBps_;
    }

    /// @notice Deploy and initialize a new fair-launch token. 100% of
    ///         supply goes to the new curve; msg.sender only ever
    ///         receives trade fees, never a pre-mine.
    function createToken(string calldata name, string calldata symbol) external returns (address token) {
        token = Clones.clone(implementation);
        MemecoinBondingCurve(token).initialize(
            name,
            symbol,
            usdc,
            router,
            msg.sender,
            defaultInitialVirtualUsdc,
            defaultGraduationThreshold,
            platformFeeRecipient,
            platformFeeBps,
            defaultMaxWalletBps
        );
        allTokens.push(token);
        emit TokenLaunched(token, msg.sender, name, symbol);
    }

    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }
}
