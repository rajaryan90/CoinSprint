// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only mock of USDC. Not part of the deliverable.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 18; // simplified for the test harness; real USDC uses 6
    }
}

/// @dev Test-only mock LP token for a pair. Not part of the deliverable.
contract MockPair is ERC20 {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) ERC20("Mock LP", "MLP") {
        token0 = token0_;
        token1 = token1_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only mock of a Uniswap-V2-style factory. Not part of the deliverable.
contract MockFactory {
    mapping(address => mapping(address => address)) public getPair;

    function createPair(address tokenA, address tokenB) public returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "pair exists");
        pair = address(new MockPair(tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

/// @dev Test-only mock of a Uniswap-V2-style router. Not part of the
///      deliverable — stands in for Arc's real DEX router, which does not
///      have a confirmed deployed address yet.
contract MockRouter {
    using SafeERC20 for IERC20;

    MockFactory public mockFactory;
    bool public shouldRevert;

    constructor(address factory_) {
        mockFactory = MockFactory(factory_);
    }

    /// @dev Test-only toggle to simulate a router that rejects addLiquidity
    ///      (paused pool, unmet minimum, whatever) — lets us verify the
    ///      graduation try/catch actually protects buy() instead of just
    ///      reasoning about it.
    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function factory() external view returns (address) {
        return address(mockFactory);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(!shouldRevert, "MockRouter: simulated failure");
        address pair = mockFactory.getPair(tokenA, tokenB);
        if (pair == address(0)) {
            pair = mockFactory.createPair(tokenA, tokenB);
        }
        IERC20(tokenA).safeTransferFrom(msg.sender, pair, amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, pair, amountBDesired);

        // Simplified LP accounting — good enough to test that graduation
        // moves the right amounts and that LP ends up burned. Not meant
        // to model real Uniswap LP math.
        liquidity = amountADesired + amountBDesired;
        MockPair(pair).mint(to, liquidity);
        return (amountADesired, amountBDesired, liquidity);
    }
}
