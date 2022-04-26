// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '@jbx-protocol-v2/contracts/structs/JBFundingCycle.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBRedemptionDelegate.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleStore.sol';

import '@uniswap/v3-periphery/libraries/OracleLibrary.sol';

contract DataSourceDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IJBRedemptionDelegate {
  address public constant weth = address(0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2);
  address public constant jbx = address(0x3abf2a4f8452ccc2cf7b4c1e4663147600646f66);
  address public constant jbxEthPool = address(0x48598ff1cee7b4d31f8f9050c2bbae98e17e6b17);

  uint32 = 120;

  function payParams(JBPayParamsData calldata _data)
    external
    view
    override
    returns (
      uint256 weight,
      string memory memo,
      IJBPayDelegate delegate
    )
  {
    return (0, _data.memo, IJBPayDelegate(address(this)));
  }

  function didPay(JBDidPayData calldata _data) external override {

    // Get the price of minting
    IJBFundingCycleStore fundingCycleStore = IJBSingleTokenPaymentTerminalStore(msg.sender)
      .fundingCycleStore();
    JBFundingCycle currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

    // Get the price of buying
    uint256 uniswapPrice = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(jbxEthPool), uint32(twapPeriod)),
      uint128(_data.amount.value),
      weth,
      jbx
    );

    // uniswapPrice < mintingPrice ? check if overflow allowance remaining > amount
    // mint for reserved (use reserved rate = false)
    // if address(this).balance < amount*uniswapPrice -> use overflow allowance
    // swap and send

    //else
    // compute reserved based on mintingPrice
    // mint to beneficiary (use reserved rate = false)
    // mint for reserved (use reserved rate = false)

  }

// Uniswap callback


  function redeemParams(JBRedeemParamsData calldata)
    external
    view
    override
    returns (
      uint256 reclaimAmount,
      string memory memo,
      IJBRedemptionDelegate delegate
    )
  {
    return (0, '', IJBRedemptionDelegate(address(this)));
  }

  function didRedeem(JBDidRedeemData calldata _data) external override {}

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId ||
      _interfaceId == type(IJBRedemptionDelegate).interfaceId;
  }
}
