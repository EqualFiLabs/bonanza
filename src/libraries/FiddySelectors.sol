// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { FiddyTokenFacet } from "../facets/FiddyTokenFacet.sol";
import { FiddyStakingFacet } from "../facets/FiddyStakingFacet.sol";
import { FiddyViewFacet } from "../facets/FiddyViewFacet.sol";

library FiddySelectors {
    function token() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = FiddyTokenFacet.name.selector;
        s[1] = FiddyTokenFacet.symbol.selector;
        s[2] = FiddyTokenFacet.decimals.selector;
        s[3] = IERC20.totalSupply.selector;
        s[4] = IERC20.balanceOf.selector;
        s[5] = IERC20.allowance.selector;
        s[6] = IERC20.approve.selector;
        s[7] = IERC20.transfer.selector;
        s[8] = IERC20.transferFrom.selector;
        s[9] = FiddyTokenFacet.initializeFiddy.selector;
        s[10] = FiddyTokenFacet.setFiddyConsumer.selector;
        s[11] = FiddyTokenFacet.isFiddyConsumer.selector;
        s[12] = FiddyTokenFacet.setFiddyConversions.selector;
        s[13] = FiddyTokenFacet.fundFiddyReserve.selector;
        s[14] = FiddyTokenFacet.depositFiddy.selector;
        s[15] = FiddyTokenFacet.withdrawFiddy.selector;
        s[16] = FiddyTokenFacet.wrapFiddy.selector;
        s[17] = FiddyTokenFacet.unwrapFiddy.selector;
        s[18] = FiddyTokenFacet.protocolMoveFiddy.selector;
    }

    function staking() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = FiddyStakingFacet.setFiddyBoostsEnabled.selector;
        s[1] = FiddyStakingFacet.checkpointFiddyAccount.selector;
        s[2] = FiddyStakingFacet.stakeFiddy.selector;
        s[3] = FiddyStakingFacet.unstakeFiddy.selector;
        s[4] = FiddyStakingFacet.registerFiddyOperator.selector;
        s[5] = FiddyStakingFacet.removeFiddyOperator.selector;
        s[6] = FiddyStakingFacet.claimFiddyRevenue.selector;
        s[7] = FiddyStakingFacet.cleanupFiddyAccount.selector;
        s[8] = FiddyStakingFacet.indexedFiddyRevenue.selector;
    }

    function views() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = FiddyViewFacet.fiddyBindings.selector;
        s[1] = FiddyViewFacet.fiddyReserve.selector;
        s[2] = FiddyViewFacet.fiddyAccount.selector;
        s[3] = FiddyViewFacet.fiddyConfig.selector;
        s[4] = FiddyViewFacet.fiddyRoundConfig.selector;
        s[5] = FiddyViewFacet.fiddyAsset.selector;
        s[6] = FiddyViewFacet.fiddyCredit.selector;
        s[7] = FiddyViewFacet.fiddyOperatorAccount.selector;
        s[8] = FiddyViewFacet.fiddyStaking.selector;
        s[9] = FiddyViewFacet.fiddyRoundRevenue.selector;
        s[10] = FiddyViewFacet.fiddyRevenueAssets.selector;
    }
}
