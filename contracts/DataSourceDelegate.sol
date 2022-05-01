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

contract DataSourceDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
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

  uint32 private constant twapPeriod = 120; // ADD SETTERS, shouldn't be constant + setter for max twap/spot deviation
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
    JBFundingCycle memory currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

    // Get the amount received if minting in pay()
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

    if (
      amountReceivedMinted < amountReceivedBought && // Swapping returns highest amount of token..
      currentAllowance - usedAllowance > _data.amount.value // .. and enough overflow allowance to cover the price
    ) return (0, _data.memo, IJBPayDelegate(address(this)));
    else return (_data.weight, _data.memo, IJBPayDelegate(address(0))); // if not, follow the pay(..) path and mint
  }

  function didPay(JBDidPayData calldata _data) external override {
    if (msg.sender != address(jbxTerminal)) revert unAuth();
    JBFundingCycle memory currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);
    _swap(_data, currentFundingCycle.weight, currentFundingCycle.reservedRate());
  }

  function _swap(
    JBDidPayData calldata _data,
    uint256 weight,
    uint256 reservedRate
  ) internal {
    // 95% swapped
    uint256 amountToSwap = (_data.amount.value * 95) / 100;

    // amount received in theory, based on twap
    uint256 twapAmountReceived = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(pool), uint32(twapPeriod)),
      uint128(amountToSwap),
      address(weth),
      address(jbx)
    );

    bytes memory _swapCallData = abi.encode(twapAmountReceived);

    //use overflow allowance to cover the cost of swap
    jbxTerminal.useAllowanceOf(
      projectId,
      amountToSwap,
      JBCurrencies.ETH,
      address(0),
      amountToSwap,
      payable(this),
      ''
    );

    // swap 95%
    pool.swap(
      _data.beneficiary,
      address(weth) < address(jbx) ? true : false, // zeroForOne <=> eth->jbx?
      int256(amountToSwap),
      0, // sqrtPriceLimit -> will check against twap in callback
      _swapCallData
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

    uint256 twapAmountReceived = abi.decode(data, (uint256));

    // Put JBX received in amount1 and weth owned in amount0
    (amount0Delta, amount1Delta) = address(jbx) > address(weth)
      ? (amount0Delta, amount1Delta)
      : (amount1Delta, amount0Delta);

    // Receiving less than 5% of the twap predicted amount? no bueno
    if (uint256(-amount1Delta) < (twapAmountReceived * 95) / 100) revert Slippage();

    // wrap eth
    weth.deposit{value: uint256(amount0Delta)}();

    // send weth
    weth.transfer(address(pool), uint256(amount0Delta));
  }

  // solhint-disable-next-line comprehensive-interface
  receive() external payable {}

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId;
  }

  function redeemParams(JBRedeemParamsData calldata _data)
    external
    view
    override
    returns (
      uint256 reclaimAmount,
      string memory memo,
      IJBRedemptionDelegate delegate
    )
  {}
}
