// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import '@jbx-protocol-v2/contracts/interfaces/IJBController.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBRedemptionDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBToken.sol';
import '@jbx-protocol-v2/contracts/structs/JBFundingCycle.sol';
import '@jbx-protocol-v2/contracts/libraries/JBTokens.sol';

import '@paulrberg/contracts/math/PRBMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol';
import '@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

contract DataSourceDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IJBRedemptionDelegate {
  error unAuth();

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant jbxEthPool =
    IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

  IJBPayoutRedemptionPaymentTerminal public immutable jbxTerminal;
  IJBSingleTokenPaymentTerminalStore public immutable terminalStore;
  IJBDirectory public immutable directory;
  IJBFundingCycleStore public immutable fundingCycleStore;
  IJBController public immutable controller;

  uint32 private constant twapPeriod = 120;
  uint256 public constant projectId = 1;

  constructor(IJBPayoutRedemptionPaymentTerminal _jbxTerminal) {
    terminalStore = _jbxTerminal.store();
    directory = _jbxTerminal.directory();
    fundingCycleStore = _jbxTerminal.store().fundingCycleStore();
    controller = IJBController(_jbxTerminal.directory().controllerOf(projectId)); // Juicebox project ID
    jbxTerminal = _jbxTerminal;
  }

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
    if (msg.sender != address(jbxTerminal)) revert unAuth();

    // Get the amount received if minting
    JBFundingCycle memory currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);
    uint256 amountReceivedMinted = PRBMath.mulDiv(
      _data.amount.value,
      currentFundingCycle.weight,
      10**18
    );

    // Get the amount received if buying
    uint256 amountReceivedBought = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(jbxEthPool), uint32(twapPeriod)),
      uint128(_data.amount.value),
      weth,
      jbx
    );

    // Get the overflow allowance left
    (uint256 currentAllowance, ) = controller.overflowAllowanceOf(
      _data.projectId,
      currentFundingCycle.configuration,
      IJBPaymentTerminal(msg.sender),
      JBTokens.ETH
    );

    uint256 usedAllowance = terminalStore.usedOverflowAllowanceOf(
      IJBSingleTokenPaymentTerminal(msg.sender),
      _data.projectId,
      currentFundingCycle.configuration
    );

    amountReceivedMinted < amountReceivedBought
      ? currentAllowance - usedAllowance > _data.amount.value
        ? _swap(_data) // Receiving more when swapping and enough overflow allowance to cover the price
        : _mint() // Receiving more when swapping but not enought overflow to cover the swap
      : _swap(); // Receiving more when minting
  }

  function _swap(JBDidPayData calldata _data) internal {
    //use overflow allowance

    // wrap eth

    // compute quote -> slippage?

    // swap
    pool.swap(
      _data.beneficiary,
      address(weth) < address(jbx) ? true : false, // zeroForOne <=> eth->jbx?
      int256(_data.amount.value),
      priceLimit,
      ''
    );
    // address recipient,
    // bool zeroForOne,
    // int256 amountSpecified,
    // uint160 sqrtPriceLimitX96,
    // bytes calldata data
  }

  // uniswapPrice < mintingPrice ? check if overflow allowance remaining > amount
  // mint for reserved (use reserved rate = false)
  // if address(this).balance < amount*uniswapPrice -> use overflow allowance

  // swap 95% and send
  // mint (rr=false) 5%

  //else
  // compute reserved based on mintingPrice
  // mint to beneficiary (use reserved rate = false)
  // mint for reserved (use reserved rate = false)

  // Uniswap callback(delta0, delta1)
  // transfer from this (eth taken from overflow allowance)

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
