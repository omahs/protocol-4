// SPDX-License-Identifier: BlueOak-1.0.0
pragma solidity 0.8.9;

import "contracts/proto0/interfaces/IMain.sol";
import "contracts/libraries/Fixed.sol";
import "./AssetP0.sol";

// https://github.com/aave/protocol-v2/blob/feat-atoken-wrapper-liquidity-mining/contracts/protocol/tokenization/StaticATokenLM.sol
interface IStaticAToken is IERC20 {
    // @return {RAY}
    function rate() external view returns (uint256);

    function ATOKEN() external view returns (AToken);

    function claimRewardsToSelf(bool forceUpdate) external;
}

interface AToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @dev All aTokens have 18 decimals, even though their underlyings may not
contract ATokenAssetP0 is AssetP0 {
    using FixLib for Fix;

    constructor(address erc20_) AssetP0(erc20_) {}

    // @return {USD/tok}
    function rateUSD() public view override returns (Fix) {
        // {qTok/tok} * {RAY/qTok} / {RAY/USD}
        return toFix(10**(decimals())).mulu(10**9).divu(IStaticAToken(_erc20).rate());
    }

    function fiatcoin() public view override returns (address) {
        return IStaticAToken(_erc20).ATOKEN().UNDERLYING_ASSET_ADDRESS();
    }

    function isFiatcoin() external pure override returns (bool) {
        return false;
    }
}
