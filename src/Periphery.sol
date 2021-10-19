// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

// External references
import { SafeERC20, ERC20 } from "@rari-capital/solmate/src/erc20/SafeERC20.sol";
import { OracleLibrary } from "./external/OracleLibrary.sol";
import { Trust } from "@rari-capital/solmate/src/auth/Trust.sol";

// Internal references
import { Errors } from "./libs/errors.sol";
import { BaseFeed as Feed } from "./feeds/BaseFeed.sol";
import { BaseFactory as Factory } from "./feeds/BaseFactory.sol";
import { GClaimManager } from "./modules/GClaimManager.sol";
import { Divider } from "./Divider.sol";
import { PoolManager } from "./fuse/PoolManager.sol";

import { ISwapRouter } from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

/// @title Periphery contract
/// @notice You can use this contract to issue, combine, and redeem Sense ERC20 Zeros and Claims
contract Periphery is Trust {
    using SafeERC20 for ERC20;
    using Errors for string;

    /// @notice Configuration
    uint24 public constant UNI_POOL_FEE = 10000; // denominated in hundredths of a bip
    uint32 public constant TWAP_PERIOD = 10 minutes; // ideal TWAP interval.

    /// @notice Mutable program state
    IUniswapV3Factory public immutable uniFactory;
    ISwapRouter public immutable uniSwapRouter;
    Divider public divider;
    PoolManager public poolManager;
    GClaimManager public gClaimManager;
    mapping(address => bool) public factories;  // feed factories -> supported

    constructor(address _divider, address _poolManager, address _uniFactory, address _uniSwapRouter, string memory name, bool whitelist, uint256 closeFactor, uint256 liqIncentive) Trust(msg.sender) {
        divider = Divider(_divider);
        poolManager = PoolManager(_poolManager);
        gClaimManager = new GClaimManager(_divider);
        uniFactory = IUniswapV3Factory(_uniFactory);
        uniSwapRouter = ISwapRouter(_uniSwapRouter);
        poolManager.deployPool(name, whitelist, closeFactor, liqIncentive);

        // approve divider to withdraw stable assets
        ERC20(divider.stable()).approve(address(divider), type(uint256).max);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Sponsor a new Series
    /// @dev Calls divider to initalise a new series
    /// @dev Creates a UNIV3 pool for Zeros and Claims
    /// @dev Onboards Zero and Claim to Sense Fuse pool
    /// @param feed Feed to associate with the Series
    /// @param maturity Maturity date for the new Series, in units of unix time
    /// @param sqrtPriceX96 Initial price of the pool as a sqrt(token1/token0) Q64.96 value
    function sponsorSeries(address feed, uint256 maturity, uint160 sqrtPriceX96) external returns (address zero, address claim) {
        // transfer INIT_STAKE from sponsor into this contract
        uint256 convertBase = 1;
        uint256 stableDecimals = ERC20(divider.stable()).decimals();
        if (stableDecimals != 18) {
            convertBase = stableDecimals > 18 ? 10 ** (stableDecimals - 18) : 10 ** (18 - stableDecimals);
        }
        ERC20(divider.stable()).safeTransferFrom(msg.sender, address(this), divider.INIT_STAKE() / convertBase);
        (zero, claim) = divider.initSeries(feed, maturity, msg.sender);
        gClaimManager.join(feed, maturity, 0); // we join just to force the gclaim deployment
        address gclaim = address(gClaimManager.gclaims(claim));
        address unipool = IUniswapV3Factory(uniFactory).createPool(gclaim, zero, UNI_POOL_FEE); // deploy UNIV3 pool
        IUniswapV3Pool(unipool).initialize(sqrtPriceX96);
        poolManager.addSeries(feed, maturity);
        emit SeriesSponsored(feed, maturity, msg.sender);
    }

    /// @notice Onboards a target
    /// @dev Deploys a new Feed via the FeedFactory
    /// @dev Onboards Target onto Fuse. Caller must know the factory address.
    /// @param target Target to onboard
    function onboardTarget(address feed, uint256 maturity, address factory, address target) external returns (address feedClone, address wtClone){
        require(factories[factory], Errors.FactoryNotSupported);
        (feedClone, wtClone) = Factory(factory).deployFeed(target);
        ERC20(target).approve(address(divider), type(uint256).max);
        poolManager.addTarget(target);
        emit TargetOnboarded(target);
    }

    /// @notice Mint Zeros and Claims of a specific Series
    /// @dev backfill amount refers to the excess that has accrued since the first Claim from a Series was deposited
    /// @dev in next versions will be calculate here. Refer to GClaimManager.excess() for more details about this value.
    /// @param feed Feed address for the Series
    /// @param maturity Maturity date for the Series
    /// @param tBal Balance of Target to deposit
    /// @param backfill Amount in target to backfill gClaims
    function swapTargetForZeros(address feed, uint256 maturity, uint256 tBal, uint256 backfill, uint256 minAccepted) external {
        (address zero, address claim, , , , , , ,) = divider.series(feed, maturity);

        // transfer target into this contract
        ERC20(Feed(feed).target()).safeTransferFrom(msg.sender, address(this), tBal + backfill);

        // issue zeros & claims with target
        uint256 issued = divider.issue(feed, maturity, tBal);

        // convert claims to gclaims
        ERC20(claim).approve(address(gClaimManager), issued);
        gClaimManager.join(feed, maturity, issued);

        // swap gclaims to zeros
        address gclaim = address(gClaimManager.gclaims(claim));
        uint256 swapped = _swap(gclaim, zero, issued, address(this), minAccepted);
        uint256 totalZeros = issued + swapped;

        // transfer issued + bought zeros to user
        ERC20(zero).transfer(msg.sender, totalZeros);

    }

    function swapTargetForClaims(address feed, uint256 maturity, uint256 tBal, uint256 minAccepted) external {
        // transfer target into this contract
        ERC20(Feed(feed).target()).safeTransferFrom(msg.sender, address(this), tBal);

        // issue zeros & claims with target
        uint256 issued = divider.issue(feed, maturity, tBal);

        // swap zeros to gclaims
        (address zero, address claim, , , , , , ,) = divider.series(feed, maturity);
        address gclaim = address(gClaimManager.gclaims(claim));
        uint256 swapped = _swap(zero, gclaim, issued, address(this), minAccepted);

        // convert gclaims to claims
        gClaimManager.exit(feed, maturity, swapped);
        uint256 totalClaims = issued + swapped;

        // transfer issued + bought claims to user
        ERC20(claim).transfer(msg.sender, totalClaims);
    }

    function swapZerosForTarget(address feed, uint256 maturity, uint256 zBal, uint256 minAccepted) external {
        (address zero, address claim, , , , , , ,) = divider.series(feed, maturity);
        address gclaim = address(gClaimManager.gclaims(claim));

        // transfer zeros into this contract
        ERC20(zero).safeTransferFrom(msg.sender, address(this), zBal);

        // get rate from uniswap
        uint256 rate = price(zero, gclaim);

        // swap some zeros for gclaims
        uint256 zerosToSell = zBal / (rate + 1);
        uint256 swapped = _swap(zero, gclaim, zerosToSell, address(this), minAccepted);

        // convert gclaims to claims
        gClaimManager.exit(feed, maturity, swapped);


        // combine zeros & claims
        divider.combine(feed, maturity, swapped);
    }

    function swapClaimsForTarget(address feed, uint256 maturity, uint256 cBal, uint256 minAccepted) external {
        (address zero, address claim, , , , , , ,) = divider.series(feed, maturity);
        address gclaim = address(gClaimManager.gclaims(claim));

        // transfer claims into this contract
        ERC20(claim).safeTransferFrom(msg.sender, address(this), cBal);

        // get rate from uniswap
        uint256 rate = price(zero, gclaim);

        // convert some gclaims to claims
        uint256 claimsToConvert = cBal / (rate + 1);
        gClaimManager.exit(feed, maturity, claimsToConvert);

        // swap gclaims for zeros
        uint256 swapped = _swap(gclaim, zero, claimsToConvert, address(this), minAccepted);

        // combine zeros & claims
        divider.combine(feed, maturity, swapped);
    }

    /* ========== VIEWS ========== */

    function price(address tokenA, address tokenB) public view returns (uint) {
        // Return tokenA/tokenB TWAP
        address pool = IUniswapV3Factory(uniFactory).getPool(tokenA, tokenB, UNI_POOL_FEE);
        int24 timeWeightedAverageTick = OracleLibrary.consult(pool, TWAP_PERIOD);
        uint128 baseUnit = uint128(10) ** uint128(ERC20(tokenA).decimals());
        return OracleLibrary.getQuoteAtTick(timeWeightedAverageTick, baseUnit, tokenA, tokenB);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address recipient, uint256 minAccepted) internal returns (uint256 amountOut) {
        // approve router to spend tokenIn.
        ERC20(tokenIn).safeApprove(address(uniSwapRouter), amountIn);

        ISwapRouter.ExactInputSingleParams memory params =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: UNI_POOL_FEE,
                recipient: recipient,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAccepted,
                sqrtPriceLimitX96: 0 // set to be 0 to ensure we swap our exact input amount
        });

        amountOut = uniSwapRouter.exactInputSingle(params); // executes the swap
    }

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Enable or disable a factory
    /// @param factory Factory's address
    /// @param isOn Flag setting this factory to enabled or disabled
    function setFactory(address factory, bool isOn) external requiresTrust {
        require(factories[factory] != isOn, Errors.ExistingValue);
        factories[factory] = isOn;
        emit FactoryChanged(factory, isOn);
    }

    /* ========== EVENTS ========== */
    event FactoryChanged(address indexed feed, bool isOn);
    event SeriesSponsored(address indexed feed, uint256 indexed maturity, address indexed sponsor);
    event TargetOnboarded(address target);

}