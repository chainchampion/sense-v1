// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

import { FixedMath } from "../external/FixedMath.sol";
import { SafeERC20, ERC20 } from "@rari-capital/solmate/src/erc20/SafeERC20.sol";

// Internal references
import { Periphery } from "../Periphery.sol";
import { Divider, TokenHandler } from "../Divider.sol";
import { WstETHAdapter } from "../adapters/lido/WstETHAdapter.sol";
import { BaseAdapter } from "../adapters/BaseAdapter.sol";
//import { LFactory } from "../adapters/lido/LFactory.sol";

import { DSTest } from "./test-helpers/DSTest.sol";
import { Assets } from "./test-helpers/Assets.sol";
import { MockFactory } from "./test-helpers/mocks/MockFactory.sol";
import { Hevm } from "./test-helpers/Hevm.sol";
import { DateTimeFull } from "./test-helpers/DateTimeFull.sol";
import { User } from "./test-helpers/User.sol";
import { LiquidityHelper } from "./test-helpers/LiquidityHelper.sol";

interface ICurveStableSwap {
    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external payable returns (uint256);
}

interface StETHInterface {
    function getSharesByPooledEth(uint256 _ethAmount) external returns (uint256);
}

interface WstETHInterface {
    function stEthPerToken() external view returns (uint256);

    function getWstETHByStETH(uint256 _stETHAmount) external returns (uint256);
}

contract WstETHAdapterTestHelper is LiquidityHelper, DSTest {
    WstETHAdapter adapter;
    Divider internal divider;
    Periphery internal periphery;
    TokenHandler internal tokenHandler;

    uint256 public constant DELTA = 150;
    uint256 public constant ISSUANCE_FEE = 0.01e18;
    uint256 public constant STAKE_SIZE = 1e18;
    uint256 public constant MIN_MATURITY = 2 weeks;
    uint256 public constant MAX_MATURITY = 14 weeks;

    function setUp() public {
        address[] memory assets = new address[](1);
        assets[0] = Assets.WSTETH;
        addLiquidity(assets);
        tokenHandler = new TokenHandler();
        divider = new Divider(address(this), address(tokenHandler));
        divider.setPeriphery(address(this));
        tokenHandler.init(address(divider));
        adapter = new WstETHAdapter(); // wstETH adapter
        BaseAdapter.AdapterParams memory adapterParams = BaseAdapter.AdapterParams({
            target: Assets.WSTETH,
            delta: DELTA,
            oracle: Assets.RARI_ORACLE,
            ifee: ISSUANCE_FEE,
            stake: Assets.DAI,
            stakeSize: STAKE_SIZE,
            minm: MIN_MATURITY,
            maxm: MAX_MATURITY,
            mode: 0
        });
        adapter.initialize(address(divider), adapterParams);
    }
}

contract WstETHAdapters is WstETHAdapterTestHelper {
    using FixedMath for uint256;

    function testWstETHAdapterScale() public {
        WstETHInterface wstETH = WstETHInterface(Assets.WSTETH);

        uint256 scale = wstETH.stEthPerToken();
        assertEq(adapter.scale(), scale);
    }

    function testGetUnderlyingPrice() public {
        uint256 price = 1e18;
        assertEq(adapter.getUnderlyingPrice(), price);
    }

    function testUnwrapTarget() public {
        uint256 wethBalanceBefore = ERC20(Assets.WETH).balanceOf(address(this));
        uint256 wstETHBalanceBefore = ERC20(Assets.WSTETH).balanceOf(address(this));
        ERC20(Assets.WSTETH).approve(address(adapter), wstETHBalanceBefore);
        uint256 minDy = ICurveStableSwap(Assets.CURVESINGLESWAP).get_dy(int128(1), int128(0), wstETHBalanceBefore);
        adapter.unwrapTarget(wstETHBalanceBefore);
        uint256 wstETHBalanceAfter = ERC20(Assets.WSTETH).balanceOf(address(this));
        uint256 wethBalanceAfter = ERC20(Assets.WETH).balanceOf(address(this));

        assertEq(wstETHBalanceAfter, 0);
        assertEq(wethBalanceBefore + minDy, wethBalanceAfter);
    }

    function testWrapUnderlying() public {
        uint256 wethBalanceBefore = ERC20(Assets.WETH).balanceOf(address(this));
        uint256 wstETHBalanceBefore = ERC20(Assets.WSTETH).balanceOf(address(this));

        ERC20(Assets.WETH).approve(address(adapter), wethBalanceBefore);
        uint256 stETH = StETHInterface(Assets.STETH).getSharesByPooledEth(wethBalanceBefore);
        uint256 wstETH = WstETHInterface(Assets.WSTETH).getWstETHByStETH(stETH);
        adapter.wrapUnderlying(wethBalanceBefore);
        uint256 wstETHBalanceAfter = ERC20(Assets.WSTETH).balanceOf(address(this));
        uint256 wethBalanceAfter = ERC20(Assets.WETH).balanceOf(address(this));

        assertEq(wethBalanceAfter, 0);
        assertEq(wstETHBalanceBefore + wstETH, wstETHBalanceAfter);
    }
}