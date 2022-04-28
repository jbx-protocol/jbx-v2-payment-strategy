// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import './interfaces/external/IWETH9.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBController.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBRedemptionDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBToken.sol';
import '@jbx-protocol-v2/contracts/libraries/JBConstants.sol';
import '@jbx-protocol-v2/contracts/libraries/JBCurrencies.sol';
import '@jbx-protocol-v2/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol-v2/contracts/libraries/JBTokens.sol';
import '@jbx-protocol-v2/contracts/structs/JBFundingCycle.sol';

import '@paulrberg/contracts/math/PRBMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

contract DataSourceDelegate is
  IJBFundingCycleDataSource,
  IJBPayDelegate,
  IJBRedemptionDelegate,
  IUniswapV3SwapCallback
{
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  error unAuth();
  error Slippage();

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

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

    // Get the amount received if swapping
    uint256 amountReceivedBought = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(pool), uint32(twapPeriod)),
      uint128(_data.amount.value),
      address(weth),
      address(jbx)
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
        ? _swap(
          _data,
          amountReceivedBought,
          currentFundingCycle.weight,
          currentFundingCycle.reservedRate()
        ) // Receiving more when swapping and enough overflow allowance to cover the price -> swap
        : _mint(_data, currentFundingCycle.weight, currentFundingCycle.reservedRate()) // Receiving more when swapping but not enought overflow to cover the swap -> mint
      : _mint(_data, currentFundingCycle.weight, currentFundingCycle.reservedRate()); // Receiving more when minting -> mint
  }

  function _swap(
    JBDidPayData calldata _data,
    uint256 twapAmountReceived,
    uint256 weight,
    uint256 reservedRate
  ) internal {
    // 95% to swap, 5% to mint
    uint256 amountToSwap = (_data.amount.value * 95) / 100;

    //use overflow allowance to cover the cost
    jbxTerminal.useAllowanceOf(
      projectId,
      amountToSwap,
      JBCurrencies.ETH,
      address(0),
      amountToSwap,
      payable(this),
      ''
    );

    // Will serve to compute deviation in the swap callback
    bytes memory swapCallbackData = abi.encode(twapAmountReceived);

    // swap 95%
    pool.swap(
      _data.beneficiary,
      address(weth) < address(jbx) ? true : false, // zeroForOne <=> eth->jbx?
      int256(amountToSwap),
      0, // sqrtPriceLimit -> will check against twap in callback
      swapCallbackData
    );

    // mint (rr = false) 5% to beneficiary (the eth stayed in Jb terminal)
    controller.mintTokensOf(
      projectId,
      (((_data.amount.value * 5) / 100) * weight) / 10**18,
      _data.beneficiary,
      '',
      false, // _preferClaimedTokens,
      false //_useReservedRate
    );

    // mint for reserved (rr=true)
    controller.mintTokensOf(
      projectId,
      (((_data.amount.value * reservedRate) / JBConstants.MAX_RESERVED_RATE) * weight) / 10**18,
      _data.beneficiary,
      '',
      false, //_preferClaimedTokens,
      true //_useReservedRate
    );
  }

  function _mint(
    JBDidPayData calldata _data,
    uint256 weight,
    uint256 reservedRate
  ) internal {
    // mint (rr = false) to beneficiary
    controller.mintTokensOf(
      projectId,
      (_data.amount.value * weight) / 10**18,
      _data.beneficiary,
      '',
      false, // _preferClaimedTokens,
      false //_useReservedRate
    );

    // mint for reserved (rr=true)
    controller.mintTokensOf(
      projectId,
      (((_data.amount.value * reservedRate) / JBConstants.MAX_RESERVED_RATE) * weight) / 10**18,
      _data.beneficiary,
      '',
      false, //_preferClaimedTokens,
      true //_useReservedRate
    );
  }

  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {
    if (msg.sender != address(pool)) revert unAuth();

    // callbackData decode
    uint256 twapAmountReceived = abi.decode(data, (uint256));

    // Is JBX token1?
    if (address(jbx) > address(weth)) {
      // Receiving less than 5% of the twap predicted amount? no bueno
      if (uint256(amount1Delta) < (twapAmountReceived * 95) / 100) revert Slippage();

      // wrap eth
      weth.deposit{value: uint256(amount0Delta)}();

      // send weth
      weth.transfer(address(pool), uint256(amount0Delta));
    } else {
      if (uint256(amount0Delta) < (twapAmountReceived * 95) / 100) revert Slippage();
      // wrap eth
      weth.deposit{value: uint256(amount1Delta)}();

      // send weth
      weth.transfer(address(pool), uint256(amount1Delta));
    }
  }

  // solhint-disable-next-line comprehensive-interface
  fallback() external payable {}

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
