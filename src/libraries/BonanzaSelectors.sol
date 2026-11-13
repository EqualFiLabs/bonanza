// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { BonanzaTokenFacet } from "../facets/BonanzaTokenFacet.sol";
import { BonanzaStakingFacet } from "../facets/BonanzaStakingFacet.sol";
import { BonanzaViewFacet } from "../facets/BonanzaViewFacet.sol";

library BonanzaSelectors {
    function token() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](19);
        s[0] = BonanzaTokenFacet.name.selector;
        s[1] = BonanzaTokenFacet.symbol.selector;
        s[2] = BonanzaTokenFacet.decimals.selector;
        s[3] = IERC20.totalSupply.selector;
        s[4] = IERC20.balanceOf.selector;
        s[5] = IERC20.allowance.selector;
        s[6] = IERC20.approve.selector;
        s[7] = IERC20.transfer.selector;
        s[8] = IERC20.transferFrom.selector;
        s[9] = BonanzaTokenFacet.initializeBonanza.selector;
        s[10] = BonanzaTokenFacet.setBonanzaConsumer.selector;
        s[11] = BonanzaTokenFacet.isBonanzaConsumer.selector;
        s[12] = BonanzaTokenFacet.setBonanzaConversions.selector;
        s[13] = BonanzaTokenFacet.fundBonanzaReserve.selector;
        s[14] = BonanzaTokenFacet.depositBonanza.selector;
        s[15] = BonanzaTokenFacet.withdrawBonanza.selector;
        s[16] = BonanzaTokenFacet.wrapBonanza.selector;
        s[17] = BonanzaTokenFacet.unwrapBonanza.selector;
        s[18] = BonanzaTokenFacet.protocolMoveBonanza.selector;
    }

    function staking() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = BonanzaStakingFacet.setBonanzaBoostsEnabled.selector;
        s[1] = BonanzaStakingFacet.checkpointBonanzaAccount.selector;
        s[2] = BonanzaStakingFacet.stakeBonanza.selector;
        s[3] = BonanzaStakingFacet.unstakeBonanza.selector;
        s[4] = BonanzaStakingFacet.registerBonanzaOperator.selector;
        s[5] = BonanzaStakingFacet.removeBonanzaOperator.selector;
        s[6] = BonanzaStakingFacet.claimBonanzaRevenue.selector;
        s[7] = BonanzaStakingFacet.cleanupBonanzaAccount.selector;
        s[8] = BonanzaStakingFacet.indexedBonanzaRevenue.selector;
    }

    function views() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](11);
        s[0] = BonanzaViewFacet.bonanzaBindings.selector;
        s[1] = BonanzaViewFacet.bonanzaReserve.selector;
        s[2] = BonanzaViewFacet.bonanzaAccount.selector;
        s[3] = BonanzaViewFacet.bonanzaConfig.selector;
        s[4] = BonanzaViewFacet.bonanzaRoundConfig.selector;
        s[5] = BonanzaViewFacet.bonanzaAsset.selector;
        s[6] = BonanzaViewFacet.bonanzaCredit.selector;
        s[7] = BonanzaViewFacet.bonanzaOperatorAccount.selector;
        s[8] = BonanzaViewFacet.bonanzaStaking.selector;
        s[9] = BonanzaViewFacet.bonanzaRoundRevenue.selector;
        s[10] = BonanzaViewFacet.bonanzaRevenueAssets.selector;
    }
}
