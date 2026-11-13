// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

interface IBonanzaProtocol {
    function protocolMoveBonanza(address from, address to, uint256 amount) external;
}

interface IBonanzaActivation {
    function multiplierBps(uint256 operatorId) external view returns (uint16);
    function activeConsumer() external view returns (address);
    function genesisCollection() external view returns (address);
}
