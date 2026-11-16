// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import { IGovernance } from "../interfaces/IGovernance.sol";

library GovernanceSelectors {
    function existing() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](14);
        s[0] = IGovernance.createLotteryConfig.selector;
        s[1] = IGovernance.setLotteryConfigEnabled.selector;
        s[2] = IGovernance.setMaxActiveRounds.selector;
        s[3] = IGovernance.integrationConfig.selector;
        s[4] = IGovernance.setIntegrationConfig.selector;
        s[5] = IGovernance.setTreasuryRecipient.selector;
        s[6] = IGovernance.setGuardian.selector;
        s[7] = IGovernance.setPaused.selector;
        s[8] = IGovernance.paused.selector;
        s[9] = IGovernance.guardian.selector;
        s[10] = IGovernance.treasuryRecipient.selector;
        s[11] = IGovernance.protocolFinalized.selector;
        s[12] = IGovernance.finalizeProtocol.selector;
        s[13] = IGovernance.createRewardLotteryConfig.selector;
    }

    function handover() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IGovernance.authority.selector;
        s[1] = IGovernance.pendingAuthority.selector;
        s[2] = IGovernance.nominateAuthority.selector;
        s[3] = IGovernance.cancelAuthorityTransfer.selector;
        s[4] = IGovernance.acceptAuthority.selector;
    }

    function all() internal pure returns (bytes4[] memory s) {
        bytes4[] memory previous = existing();
        bytes4[] memory added = handover();
        s = new bytes4[](previous.length + added.length);
        for (uint256 i; i < previous.length; ++i) {
            s[i] = previous[i];
        }
        for (uint256 i; i < added.length; ++i) {
            s[previous.length + i] = added[i];
        }
    }
}
