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
  event Test(uint256);
  error unAuth();
  error Slippage();

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

  IJBPayoutRedemptionPaymentTerminal public immutable jbxTerminal;
  IJBSingleTokenPaymentTerminalStore public immutable terminalStore;
  IJBDirectory public immutable directory;
  IJBFundingCycleStore public immutable fundingCycleStore;

  uint32 private constant twapPeriod = 120; // ADD SETTERS, shouldn't be constant + setter for max twap/spot deviation
  uint256 public constant projectId = 1;
  uint256 public immutable reservedRate;
  uint256 private _swapTokenCount;
  uint256 private _issueTokenCount;

  constructor(IJBPayoutRedemptionPaymentTerminal _jbxTerminal, uint256 _reservedRate) {
    terminalStore = _jbxTerminal.store();
    directory = _jbxTerminal.directory();
    fundingCycleStore = _jbxTerminal.store().fundingCycleStore();
    jbxTerminal = _jbxTerminal;
    reservedRate = _reservedRate;
  }

  function payParams(JBPayParamsData calldata _data)
    external
    override
    returns (
      uint256 weight,
      string memory memo,
      IJBPayDelegate delegate
    )
  {
    // The terminal must be the jbx terminal.
    if (_data.terminal != jbxTerminal) revert unAuth();

    // Get the current funding cycle.
    JBFundingCycle memory _currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

    // The funding cycle's reserved rate must be 100%, otherwise proceed with the normal behavior.
    if (_currentFundingCycle.reservedRate() != JBConstants.MAX_RESERVED_RATE)
      return (_data.weight, _data.memo, IJBPayDelegate(address(0)));

    // Get the token count that would be distributed by minting a new supply.
    uint256 _mintTokenCountQuote = PRBMath.mulDiv(
      _data.amount.value,
      _currentFundingCycle.weight,
      10**18
    );

    // Get the token count that would be distributed by swapping.
    uint256 _swapTokenCountQuote = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(pool), uint32(twapPeriod)),
      uint128(_data.amount.value),
      address(weth),
      address(jbx)
    );
    emit Test(_swapTokenCountQuote);
    // Get the current overflow allowance.
    (uint256 _currentAllowance, ) = IJBController(jbxTerminal.directory().controllerOf(projectId))
      .overflowAllowanceOf(
        _data.projectId,
        _currentFundingCycle.configuration,
        _data.terminal,
        JBTokens.ETH
      );

    // Get the current used amount of overflow.
    uint256 _usedAllowance = terminalStore.usedOverflowAllowanceOf(
      IJBSingleTokenPaymentTerminal(address(_data.terminal)),
      _data.projectId,
      _currentFundingCycle.configuration
    );

    // If swapping yields a better rate and there's enough overflow allowance to cover the swap.
    if (
      _mintTokenCountQuote < _swapTokenCountQuote &&
      _currentAllowance - _usedAllowance > _data.amount.value
    ) {
      // Get the weight which represents the amount being swapped for.
      uint256 _swapWeight = PRBMath.mulDiv(_swapTokenCountQuote, 1E18, _data.amount.value);

      // Get the weight which should be used to distribute reserved tokens given a 100% reserved rate.
      uint256 _reservedWeight = PRBMath.mulDiv(
        _swapWeight,
        JBConstants.MAX_RESERVED_RATE,
        JBConstants.MAX_RESERVED_RATE - reservedRate
      ) - _swapWeight;

      // Store the token count to swap. This will be referenced and reset in the delegate.
      _swapTokenCount = _swapTokenCountQuote;

      // Return the weight of reserved tokens to distribute, forward the memo, and set this contract as the delegate to execute the swap.
      return (_reservedWeight, _data.memo, IJBPayDelegate(address(this)));
    } else {
      // Get the weight which should be used to distribute reserved tokens given a 100% reserved rate.
      uint256 _reservedWeight = PRBMath.mulDiv(
        _data.weight,
        JBConstants.MAX_RESERVED_RATE,
        JBConstants.MAX_RESERVED_RATE - reservedRate
      ) - _data.weight;

      // Store the token count to mint. This will be referenced and reset in the delegate.
      _issueTokenCount = _mintTokenCountQuote;

      // Get a reference to the weight of reserved tokens to distribute.
      return (_reservedWeight, _data.memo, IJBPayDelegate(address(this)));
    }
  }

  function didPay(JBDidPayData calldata _data) external override {
    if (msg.sender != address(jbxTerminal)) revert unAuth();
    JBFundingCycle memory currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

    // Swap if needed.
    if (_swapTokenCount > 0) {
      // Execute the swap.
      _swap(_data);

      // Reset the storage slot.
      _swapTokenCount = 0;
    }

    // Mint if needed.
    if (_issueTokenCount > 0) {
      // Mint new tokens for
      IJBController(jbxTerminal.directory().controllerOf(projectId)).mintTokensOf(
        projectId,
        _issueTokenCount,
        _data.beneficiary,
        '',
        false, //_preferClaimedTokens,
        false //_useReservedRate
      );

      // Reset the storage slot.
      _issueTokenCount = 0;
    }
  }

  function _swap(JBDidPayData calldata _data) internal {
    // Swap 95% of the amount paid in.
    uint256 _amountToSwap = (_data.amount.value * 95) / 100;

    bytes memory _swapCallData = abi.encode(_swapTokenCount);

    // Use overflow allowance to cover the cost of swap.
    jbxTerminal.useAllowanceOf(
      projectId,
      _amountToSwap,
      JBCurrencies.ETH,
      address(0),
      _amountToSwap,
      payable(this),
      ''
    );

    // Execute the swap.
    pool.swap(
      _data.beneficiary,
      address(weth) < address(jbx) ? true : false, // zeroForOne <=> eth->jbx?
      int256(_amountToSwap),
      0, // sqrtPriceLimit -> will check against twap in callback
      _swapCallData
    );
  }

  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {
    if (msg.sender != address(pool)) revert unAuth();

    uint256 _twapAmountReceived = abi.decode(data, (uint256));

    // Put JBX received in amount1 and weth owned in amount0
    (amount0Delta, amount1Delta) = address(jbx) > address(weth)
      ? (amount0Delta, amount1Delta)
      : (amount1Delta, amount0Delta);

    // Receiving less than 5% of the twap predicted amount? no bueno
    if (uint256(-amount1Delta) < (_twapAmountReceived * 95) / 100) revert Slippage();

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
    override
    returns (
      uint256 reclaimAmount,
      string memory memo,
      IJBRedemptionDelegate delegate
    )
  {}
}
