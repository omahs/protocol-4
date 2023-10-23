// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.19;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "../../../libraries/Fixed.sol";
import "../AppreciatingFiatCollateral.sol";
import "../OracleLib.sol";
import "./ICusdcV3Wrapper.sol";
import "./vendor/IComet.sol";

/**
 * @title CTokenV3Collateral
 * @notice Collateral plugin for Compound V3,
 * tok = wcUSDC
 * ref = USDC
 * tar = USD
 * UoA = USD
 */
contract CTokenV3Collateral is AppreciatingFiatCollateral {
    struct CometCollateralConfig {
        IERC20 rewardERC20;
        uint256 reservesThresholdIffy;
        uint256 reservesThresholdDisabled;
    }

    using OracleLib for AggregatorV3Interface;
    using FixLib for uint192;

    IERC20 public immutable rewardERC20;
    IComet public immutable comet;
    uint256 public immutable reservesThresholdIffy; // {qUSDC}
    uint8 public immutable cometDecimals;

    /// @param config.chainlinkFeed Feed units: {UoA/ref}
    constructor(
        CollateralConfig memory config,
        uint192 revenueHiding,
        uint256 reservesThresholdIffy_
    ) AppreciatingFiatCollateral(config, revenueHiding) {
        require(config.defaultThreshold > 0, "defaultThreshold zero");
        rewardERC20 = ICusdcV3Wrapper(address(config.erc20)).rewardERC20();
        comet = IComet(address(ICusdcV3Wrapper(address(erc20)).underlyingComet()));
        reservesThresholdIffy = reservesThresholdIffy_;
        cometDecimals = comet.decimals();
    }

    function bal(address account) external view override(Asset, IAsset) returns (uint192) {
        return shiftl_toFix(erc20.balanceOf(account), -int8(erc20Decimals));
    }

    /// DEPRECATED: claimRewards() will be removed from all assets and collateral plugins
    function claimRewards() external override(Asset, IRewardable) {
        IRewardable(address(erc20)).claimRewards();
    }

    function _underlyingRefPerTok() internal view virtual override returns (uint192) {
        return shiftl_toFix(ICusdcV3Wrapper(address(erc20)).exchangeRate(), -int8(cometDecimals));
    }

    /// Refresh exchange rates and update default status.
    /// @dev Should not need to override: can handle collateral with variable refPerTok()
    function refresh() public virtual override {
        ICusdcV3Wrapper(address(erc20)).accrue();

        CollateralStatus oldStatus = status();

        // Check for hard default
        // must happen before tryPrice() call since `refPerTok()` returns a stored value

        // revenue hiding: do not DISABLE if drawdown is small
        uint192 underlyingRefPerTok = _underlyingRefPerTok();

        // {ref/tok} = {ref/tok} * {1}
        uint192 hiddenReferencePrice = underlyingRefPerTok.mul(revenueShowing);

        // uint192(<) is equivalent to Fix.lt
        if (underlyingRefPerTok < exposedReferencePrice) {
            exposedReferencePrice = underlyingRefPerTok;
            markStatus(CollateralStatus.DISABLED);
        } else if (hiddenReferencePrice > exposedReferencePrice) {
            exposedReferencePrice = hiddenReferencePrice;
        }

        int256 cometReserves = comet.getReserves();
        if (cometReserves < 0) {
            markStatus(CollateralStatus.DISABLED);
        } else if (uint256(cometReserves) < reservesThresholdIffy) {
            markStatus(CollateralStatus.IFFY);
        } else {
            // Check for soft default + save prices
            try this.tryPrice() returns (uint192 low, uint192 high, uint192 pegPrice) {
                // {UoA/tok}, {UoA/tok}, {target/ref}
                // (0, 0) is a valid price; (0, FIX_MAX) is unpriced

                // Save prices if priced
                if (high < FIX_MAX) {
                    savedLowPrice = low;
                    savedHighPrice = high;
                    lastSave = uint48(block.timestamp);
                } else {
                    // must be unpriced
                    // untested:
                    //      validated in other plugins, cost to test here is high
                    assert(low == 0);
                }

                // If the price is below the default-threshold price, default eventually
                // uint192(+/-) is the same as Fix.plus/minus
                if (pegPrice < pegBottom || pegPrice > pegTop || low == 0) {
                    markStatus(CollateralStatus.IFFY);
                } else {
                    markStatus(CollateralStatus.SOUND);
                }
            } catch (bytes memory errData) {
                // see: docs/solidity-style.md#Catching-Empty-Data
                if (errData.length == 0) revert(); // solhint-disable-line reason-string
                markStatus(CollateralStatus.IFFY);
            }
        }

        CollateralStatus newStatus = status();
        if (oldStatus != newStatus) {
            emit CollateralStatusChanged(oldStatus, newStatus);
        }
    }
}
