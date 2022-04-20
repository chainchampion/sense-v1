// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

// External references
import { ERC20 } from "@rari-capital/solmate/src/tokens/ERC20.sol";
import { SafeTransferLib } from "@rari-capital/solmate/src/utils/SafeTransferLib.sol";

// Internal references
import { Errors } from "@sense-finance/v1-utils/src/libs/Errors.sol";
import { CropsAdapter } from "../CropsAdapter.sol";
import { CTokenLike } from "../compound/CAdapter.sol";

interface WETHLike {
    function deposit() external payable;

    function withdraw(uint256 wad) external;
}

interface FETHTokenLike {
    ///@notice Send Ether to CEther to mint
    function mint() external payable;
}

interface FTokenLike {
    function isCEther() external view returns (bool);
}

interface FComptrollerLike {
    function markets(address target) external returns (bool isListed, uint256 collateralFactorMantissa);

    function oracle() external returns (address);

    function getRewardsDistributors() external view returns (address[] memory);
}

interface RewardsDistributorLike {
    ///
    /// @notice Claim all the rewards accrued by holder in the specified markets
    /// @param holder The address to claim rewards for
    ///
    function claimRewards(address holder) external;

    function marketState(address marker) external view returns (uint224 index, uint32 lastUpdatedTimestamp);

    function rewardToken() external view returns (address rewardToken);
}

interface PriceOracleLike {
    /// @notice Get the price of an underlying asset.
    /// @param target The target asset to get the underlying price of.
    /// @return The underlying asset price in ETH as a mantissa (scaled by 1e18).
    /// Zero means the price is unavailable.
    function getUnderlyingPrice(address target) external view returns (uint256);

    function price(address underlying) external view returns (uint256);
}

/// @notice Adapter contract for fTokens
contract FAdapter is CropsAdapter {
    using SafeTransferLib for ERC20;

    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant FETH = 0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5;

    mapping(address => address) public rewardsDistributors; // rewards distributors for reward token

    address public comptroller;
    bool public isFETH;
    uint8 public uDecimals;

    constructor(
        address _divider,
        address _comptroller,
        AdapterParams memory _adapterParams,
        address[] memory _rewardTokens,
        address[] memory _rewardsDistributors
    ) CropsAdapter(_divider, _adapterParams, _rewardTokens) {
        rewardTokens = _rewardTokens;
        comptroller = _comptroller;
        isFETH = FTokenLike(_adapterParams.target).isCEther();

        ERC20(_adapterParams.underlying).approve(_adapterParams.target, type(uint256).max);
        uDecimals = CTokenLike(_adapterParams.underlying).decimals();

        // Initialize rewardsDistributors mapping
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            rewardsDistributors[_rewardTokens[i]] = _rewardsDistributors[i];
        }
    }

    /// @return Exchange rate from Target to Underlying using Compound's `exchangeRateCurrent()`, normed to 18 decimals
    function scale() external override returns (uint256) {
        uint256 exRate = CTokenLike(adapterParams.target).exchangeRateCurrent();
        return _to18Decimals(exRate);
    }

    function scaleStored() external view override returns (uint256) {
        uint256 exRate = CTokenLike(adapterParams.target).exchangeRateStored();
        return _to18Decimals(exRate);
    }

    function _claimRewards() internal virtual override {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            RewardsDistributorLike(rewardsDistributors[rewardTokens[i]]).claimRewards(address(this));
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
            if (CTokenLike(adapterParams.target).mint(uBal) != 0) revert Errors.MintFailed();
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
        if (CTokenLike(adapterParams.target).redeem(tBal) != 0) revert Errors.RedeemFailed();
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

    function setRewardTokens(address[] memory _rewardTokens, address[] memory _rewardsDistributors)
        public
        virtual
        requiresTrust
    {
        super.setRewardTokens(_rewardTokens);
        for (uint256 i = 0; i < _rewardTokens.length; i++) {
            rewardsDistributors[_rewardsDistributors[i]] = _rewardTokens[i];
        }
    }

    fallback() external payable {}
}
