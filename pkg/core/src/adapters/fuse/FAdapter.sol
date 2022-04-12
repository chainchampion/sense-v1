// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

// External references
import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";

// Internal references
import { Errors } from "@sense-finance/v1-utils/src/libs/Errors.sol";
import { CropAdapter } from "../CropAdapter.sol";

interface WETHLike {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

interface FTokenLike {
    /// @notice cToken is convertible into an ever increasing quantity of the underlying asset, as interest accrues in
    /// the market. This function returns the exchange rate between a cToken and the underlying asset.
    /// @dev returns the current exchange rate as an uint, scaled by 1 * 10^(18 - 8 + Underlying Token Decimals).
    function exchangeRateCurrent() external returns (uint256);

    /// @notice Calculates the exchange rate from the underlying to the CToken
    /// @dev This function does not accrue interest before calculating the exchange rate
    /// @return Calculated exchange rate scaled by 1e18
    function exchangeRateStored() external view returns (uint256);

    function decimals() external view returns (uint8);

    function underlying() external view returns (address);

    /// The mint function transfers an asset into the protocol, which begins accumulating interest based
    /// on the current Supply Rate for the asset. The user receives a quantity of cTokens equal to the
    /// underlying tokens supplied, divided by the current Exchange Rate.
    /// @param mintAmount The amount of the asset to be supplied, in units of the underlying asset.
    /// @return 0 on success, otherwise an Error code
    function mint(uint256 mintAmount) external returns (uint256);

    /// The redeem function converts a specified quantity of cTokens into the underlying asset, and returns
    /// them to the user. The amount of underlying tokens received is equal to the quantity of cTokens redeemed,
    /// multiplied by the current Exchange Rate. The amount redeemed must be less than the user's Account Liquidity
    /// and the market's available liquidity.
    /// @param redeemTokens The number of cTokens to be redeemed.
    /// @return 0 on success, otherwise an Error code
    function redeem(uint256 redeemTokens) external returns (uint256);
}

interface FETHTokenLike {
    ///@notice Send Ether to CEther to mint
    function mint() external payable;
}

interface ComptrollerLike {
    /// @notice Claim all the comp accrued by holder in the specified markets
    /// @param holder The address to claim COMP for
    /// @param cTokens The list of markets to claim COMP in
    function claimComp(address holder, address[] memory cTokens) external;

    function markets(address target) external returns (bool isListed, uint256 collateralFactorMantissa);

    function oracle() external returns (address);

    function getRewardsDistributors() external view returns (address[] memory);
}

interface RewardsDistributorLike {
    function rewardToken() external view returns (address rewardToken);

    function claimRewards(address owner) external;

    function marketState(address marker) external view returns (uint224 index, uint32 lastUpdatedTimestamp);
}

interface PriceOracleLike {
    /// @notice Get the price of an underlying asset.
    /// @param target The target asset to get the underlying price of.
    /// @return The underlying asset price in ETH as a mantissa (scaled by 1e18).
    /// Zero means the price is unavailable.
    function getUnderlyingPrice(address target) external view returns (uint256);

    function price(address underlying) external view returns (uint256);
}

/// @notice Adapter contract for cTokens
contract FAdapter is CropAdapter {
    using SafeTransferLib for ERC20;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant FETH = 0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5;

    address public comptroller;
    bool public isFETH;
    uint8 public uDecimals;

    constructor(
        address _divider,
        address _comptroller,
        AdapterParams memory _adapterParams,
        address[] memory _rewardTokens
    ) CropAdapter(_divider, _adapterParams, _rewardTokens) {
        // Sanity check: underlying passed must equal to target's underlying
        // TODO: do we need this sanity check?
        address underlying = (_adapterParams.underlying == address(0) || _adapterParams.underlying == WETH)
            ? WETH
            : FTokenLike(_adapterParams.target).underlying();
        if (_adapterParams.underlying != underlying) revert Errors.InvalidParam(); // TODO: revert or just override with the correrct one?

        comptroller = _comptroller;

        // Initialise rewardTokens by calling getRewardsDistributors() -> rewardToken(). Skip array contains addresses
        if (_rewardTokens.length > 0) {
            address[] memory rewardsDistributors = ComptrollerLike(comptroller).getRewardsDistributors();
            for (uint256 i = 0; i < rewardsDistributors.length; i++) {
                rewardTokens.push(RewardsDistributorLike(rewardsDistributors[i]).rewardToken());
            }
        }

        isFETH = _adapterParams.underlying == WETH; // TODO: is this okay?
        ERC20(_adapterParams.underlying).approve(_adapterParams.target, type(uint256).max);
        uDecimals = FTokenLike(_adapterParams.underlying).decimals();
    }

    /// @return Exchange rate from Target to Underlying using Compound's `exchangeRateCurrent()`, normed to 18 decimals
    function scale() external override returns (uint256) {
        // return FTokenLike(adapterParams.target).exchangeRateCurrent();
        uint256 exRate = FTokenLike(adapterParams.target).exchangeRateCurrent();
        return _to18Decimals(exRate);
    }

    function scaleStored() external view override returns (uint256) {
        // return FTokenLike(adapterParams.target).exchangeRateStored();
        uint256 exRate = FTokenLike(adapterParams.target).exchangeRateStored();
        return _to18Decimals(exRate);
    }

    function _claimRewards() internal virtual override {
        address[] memory rewardsDistributors = ComptrollerLike(comptroller).getRewardsDistributors();
        for (uint256 i = 0; i < rewardsDistributors.length; i++) {
            (, uint32 lastUpdatedTimestamp) = RewardsDistributorLike(rewardsDistributors[i]).marketState(
                adapterParams.target
            );
            if (lastUpdatedTimestamp > 0) RewardsDistributorLike(rewardsDistributors[i]).claimRewards(address(this));
        }
    }

    function getUnderlyingPrice() external view override returns (uint256 price) {
        price = isFETH ? 1e18 : PriceOracleLike(adapterParams.oracle).price(adapterParams.underlying);
    }

    function wrapUnderlying(uint256 uBal) external override returns (uint256 tBal) {
        ERC20 t = ERC20(adapterParams.target);

        ERC20(adapterParams.underlying).safeTransferFrom(msg.sender, address(this), uBal); // pull underlying
        if (isFETH) WETHLike(WETH).withdraw(uBal); // unwrap WETH into ETH

        // Mint target
        uint256 tBalBefore = t.balanceOf(address(this));
        if (isFETH) {
            FETHTokenLike(adapterParams.target).mint{ value: uBal }();
        } else {
            if (FTokenLike(adapterParams.target).mint(uBal) != 0) revert Errors.MintFailed();
        }
        uint256 tBalAfter = t.balanceOf(address(this));

        // Transfer target to sender
        t.safeTransfer(msg.sender, tBal = tBalAfter - tBalBefore);
    }

    function unwrapTarget(uint256 tBal) external override returns (uint256 uBal) {
        ERC20 u = ERC20(adapterParams.underlying);
        ERC20(adapterParams.target).safeTransferFrom(msg.sender, address(this), tBal); // pull target

        // Redeem target for underlying
        uint256 uBalBefore = isFETH ? address(this).balance : u.balanceOf(address(this));
        if (FTokenLike(adapterParams.target).redeem(tBal) != 0) revert Errors.RedeemFailed();
        uint256 uBalAfter = isFETH ? address(this).balance : u.balanceOf(address(this));
        unchecked {
            uBal = uBalAfter - uBalBefore;
        }

        if (isFETH) {
            // Deposit ETH into WETH contract
            (bool success, ) = WETH.call{ value: uBal }("");
            if (!success) revert Errors.TransferFailed();
        }

        // Transfer underlying to sender
        ERC20(adapterParams.underlying).safeTransfer(msg.sender, uBal);
    }

    function _to18Decimals(uint256 exRate) internal view returns (uint256) {
        // From the Compound docs:
        // "exchangeRateCurrent() returns the exchange rate, scaled by 1 * 10^(18 - 8 + Underlying Token Decimals)"
        //
        // The equation to norm an asset to 18 decimals is:
        // `num * 10**(18 - decimals)`
        //
        // So, when we try to norm exRate to 18 decimals, we get the following:
        // `exRate * 10**(18 - exRateDecimals)`
        // -> `exRate * 10**(18 - (18 - 8 + uDecimals))`
        // -> `exRate * 10**(8 - uDecimals)`
        // -> `exRate / 10**(uDecimals - 8)`
        return uDecimals >= 8 ? exRate / 10**(uDecimals - 8) : exRate * 10**(8 - uDecimals);
    }

    fallback() external payable {}
}