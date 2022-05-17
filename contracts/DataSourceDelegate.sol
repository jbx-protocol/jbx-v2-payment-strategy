// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import './interfaces/external/IWETH9.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBController/1.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBProjects.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBRedemptionDelegate.sol';
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

/**
  @title
    Juicebox Project DataSource and Delegate: project token emission control
  @notice Will split the token emission in terminal.pay(..) in 3 paths, based on the funding cycle reserved rate
          and the amount of token the beneficiary would get (to maximise it):
          - funding cycle reserved rate is < max reserved rate: this datasource & delegate
            logic is bypassed and the funding cycle's reserved rate is used.
          - funding cycle reserved rate == max rate and minting emission yield more token
            for the beneficiary: minting is privilegied
          - funding cycle reserved rate == max rate and swapping the eth contributed on Uniswap
            yield more token for the beneficiary: the overflow allowance is used to swap
  @dev    This contract needs to use an overflow allowance (role USE_ALLOWANCE granted in JBOperatorStore)
          TWAP period and spot-twap deviation should carefully be set, and the Uniswap pool cardinality
           should be increased accordingly - failing to do so would result in potential price manipulation
          The amount received by the beneficiary are based on value * weight, the reserved token are emitted
           on top (either via new emission if minter, or via additional use of the overflow to swap them)
*/

contract DataSourceDelegate is IJBFundingCycleDataSource, IJBPayDelegate, IUniswapV3SwapCallback {
  using JBFundingCycleMetadataResolver for JBFundingCycle;

  //*********************************************************************//
  // --------------------------- custom errors ------------------------- //
  //*********************************************************************//

  error Datasource_unauth();
  error Delegate_unauth();
  error Callback_unauth();
  error Callback_slippage();
  error setTwapDeviation_unauth();
  error setReservedRate_unauth();
  error setSwappedPortion_unauth();
  error setTwapPeriod_unauth();

  //*********************************************************************//
  // --------------------------- unherited events----------------------- //
  //*********************************************************************//

  event NewTwapPeriod(uint32 oldTwapPeriod, uint32 newTwapPeriod);
  event NewTwapDeviation(uint256 oldTwapDeviation, uint256 newTwapDeviation);
  event NewReservedRate(uint256 oldReservedRate, uint256 newReservedRate);
  event NewSwappedPortion(uint256 oldSwappedPortion, uint256 newSwappedPortion);

  //*********************************************************************//
  // --------------------- private constant properties ----------------- //
  //*********************************************************************//

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66); // Replace by terminal token?
  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17); // Then this immutable and call uni factory in constructor

  //*********************************************************************//
  // --------------------- public constant properties ------------------ //
  //*********************************************************************//

  IJBPayoutRedemptionPaymentTerminal public immutable jbxTerminal;
  IJBSingleTokenPaymentTerminalStore public immutable terminalStore;
  IJBDirectory public immutable directory;
  IJBFundingCycleStore public immutable fundingCycleStore;
  uint256 public constant projectId = 1;

  //*********************************************************************//
  // --------------------- public stored properties -------------------- //
  //*********************************************************************//

  uint32 public twapPeriod = 120;
  uint256 public maxTwapDeviation = 10;
  uint256 public swappedPortion = 950;
  uint256 public reservedRate;
  uint256 private _swapTokenCount;
  uint256 private _issueTokenCount;

  constructor(IJBPayoutRedemptionPaymentTerminal _jbxTerminal, uint256 _reservedRate) {
    terminalStore = _jbxTerminal.store();
    directory = _jbxTerminal.directory();
    fundingCycleStore = _jbxTerminal.store().fundingCycleStore();
    jbxTerminal = _jbxTerminal;
    reservedRate = _reservedRate;
  }

  /**
    @notice
    The datasource implementation

    @dev    the quote to swap is based on an amount in of 95% of the value sent + an amount corresponding to the reserved
            rate, coming from the treasury

    @param _data the data passed to the data source in terminal.pay(..)

    @return weight the weight to use (the one passed if not max reserved rate, 0 if swapping or the one corresponding
            to the reserved token to mint if minting)
    @return memo the original memo passed
    @return delegate the address of this contract, passed if minting or swapiing is required (to trigger the delegate functIon)
  */
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
    if (msg.sender != address(jbxTerminal.store())) revert Datasource_unauth();

    // Get the current funding cycle.
    JBFundingCycle memory _currentFundingCycle = fundingCycleStore.currentOf(_data.projectId);

    // The funding cycle's reserved rate must be 100%, otherwise proceed with the normal behavior.
    if (_currentFundingCycle.reservedRate() != JBConstants.MAX_RESERVED_RATE)
      return (_data.weight, _data.memo, IJBPayDelegate(address(0)));

    // The amount including the contribution to the reserved token (100% = _data.value+reserved token)
    uint256 entireAmount = PRBMath.mulDiv(
      _data.amount.value,
      JBConstants.MAX_RESERVED_RATE,
      JBConstants.MAX_RESERVED_RATE - reservedRate
    );

    // Get the token count that would be distributed to the beneficiary by minting a new supply.
    uint256 _mintTokenCountQuote = PRBMath.mulDiv(
      entireAmount,
      _currentFundingCycle.weight,
      10**18
    );

    // Get the token count that would be distributed to the beneficiary by swapping.
    uint256 _swapTokenCountQuote = OracleLibrary.getQuoteAtTick(
      OracleLibrary.consult(address(pool), uint32(twapPeriod)),
      uint128(entireAmount),
      address(weth),
      address(jbx)
    );

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

    // The amount of 95% x msg.value + the Juicebox treasury part to cover the swap for reserved token
    uint256 totalToSwap = PRBMath.mulDiv(
      (_data.amount.value * 95) / 100,
      JBConstants.MAX_RESERVED_RATE,
      JBConstants.MAX_RESERVED_RATE - reservedRate
    );

    // If swapping yields a better rate and there's enough overflow allowance to cover the swap.
    if (
      _mintTokenCountQuote < _swapTokenCountQuote &&
      _currentAllowance - _usedAllowance > totalToSwap
    ) {
      // Store the token count to swap. This will be referenced and reset in the delegate.
      _swapTokenCount = OracleLibrary.getQuoteAtTick(
        OracleLibrary.consult(address(pool), uint32(twapPeriod)),
        uint128(totalToSwap),
        address(weth),
        address(jbx)
      );

      // Do not mint, forward the memo, and set this contract as the delegate to execute the swap.
      return (0, _data.memo, IJBPayDelegate(address(this)));
    } else {
      // Get the weight which should be used to distribute reserved tokens given a 100% reserved rate.
      uint256 _reservedWeight = PRBMath.mulDiv(
        _data.weight,
        JBConstants.MAX_RESERVED_RATE,
        JBConstants.MAX_RESERVED_RATE - reservedRate
      ) - _data.weight;

      // Store the token count to mint for the beneficiary. This will be referenced and reset in the delegate.
      _issueTokenCount = PRBMath.mulDiv(_data.amount.value, _currentFundingCycle.weight, 10**18);

      // Get a reference to the weight of reserved tokens to distribute.
      return (_reservedWeight, _data.memo, IJBPayDelegate(address(this)));
    }
  }

  /**
    @notice
    Delegate to either swap or mint to the beneficiary (the mint to reserved being done by the delegate function, via
    the weight).

    @param _data the delegate data passed by the terminal
   */
  function didPay(JBDidPayData calldata _data) external override {
    if (msg.sender != address(jbxTerminal)) revert Delegate_unauth();

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
    // Swap 95% of the amount paid in + the reserved token
    uint256 _amountToSwap = PRBMath.mulDiv(
      (_data.amount.value * swappedPortion) / 1000,
      JBConstants.MAX_RESERVED_RATE,
      JBConstants.MAX_RESERVED_RATE - reservedRate
    );

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
    (int256 amount0, int256 amount1) = pool.swap(
      address(this),
      address(weth) < address(jbx) ? true : false, // zeroForOne <=> eth->jbx?
      int256(_amountToSwap), // Positive -> exact input
      0, // No price limit, amount received will be checked against twap in callback
      _swapCallData
    );

    // Logic now based on effective token sent, to factor price impact/ticks crossing
    uint256 tokenBalance = address(weth) < address(jbx) ? uint256(-amount1) : uint256(-amount0); // weth token0?

    uint256 amountForReserved = PRBMath.mulDiv(
      tokenBalance,
      reservedRate,
      JBConstants.MAX_RESERVED_RATE
    );

    // Burn and mint to reserved tokens
    IJBController(jbxTerminal.directory().controllerOf(projectId)).burnTokensOf(
      address(this),
      projectId,
      amountForReserved,
      '',
      false // Prefer claimed
    );

    // Mint new tokens for reserve
    IJBController(jbxTerminal.directory().controllerOf(projectId)).mintTokensOf(
      projectId,
      amountForReserved,
      _data.beneficiary,
      '',
      false, //_preferClaimedTokens,
      true //_useReservedRate
    );

    // Transfer to beneficiary
    jbx.transfer(projectId, _data.beneficiary, tokenBalance - amountForReserved);
  }

  /**
    @notice
    The Uniswap V3 pool callback (where token transfer should happens)

    @dev the twap-spot deviation is checked in this callback
  */
  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external override {
    if (msg.sender != address(pool)) revert Callback_unauth();

    uint256 _twapAmountReceived = abi.decode(data, (uint256));

    // Put JBX received in amount1 and weth owned in amount0
    (amount0Delta, amount1Delta) = address(jbx) > address(weth)
      ? (amount0Delta, amount1Delta)
      : (amount1Delta, amount0Delta);

    // Receiving more or less than 99% of the twap predicted amount (slippage or price manipulation)? no bueno
    if (
      uint256(-amount1Delta) <
      PRBMath.mulDiv(_twapAmountReceived, (1000 - maxTwapDeviation), 1000) ||
      uint256(-amount1Delta) > PRBMath.mulDiv(_twapAmountReceived, (1000 + maxTwapDeviation), 1000)
    ) revert Callback_slippage();

    // wrap eth
    weth.deposit{value: uint256(amount0Delta)}();

    // send weth to the pool
    weth.transfer(address(pool), uint256(amount0Delta));
  }

  /**
    @dev  in order to receive eth from the overflow allowance
  */
  // solhint-disable-next-line comprehensive-interface
  receive() external payable {}

  function supportsInterface(bytes4 _interfaceId) external pure override returns (bool) {
    return
      _interfaceId == type(IJBFundingCycleDataSource).interfaceId ||
      _interfaceId == type(IJBPayDelegate).interfaceId;
  }

  /**
    @dev unused, for interface implementation completion
  */
  function redeemParams(JBRedeemParamsData calldata _data)
    external
    override
    returns (
      uint256 reclaimAmount,
      string memory memo,
      IJBRedemptionDelegate delegate
    )
  {}

  function setTwapPeriod(uint32 _time) external {
    if (msg.sender == IJBProjects(directory.projects()).ownerOf(projectId))
      revert setTwapPeriod_unauth();
    emit NewTwapPeriod(twapPeriod, _time);
    twapPeriod = _time;
  }

  function setMaxTwapDeviation(uint256 _deviation) external {
    if (msg.sender == IJBProjects(directory.projects()).ownerOf(projectId))
      revert setTwapDeviation_unauth();
    emit NewTwapDeviation(maxTwapDeviation, _deviation);
    maxTwapDeviation = _deviation;
  }

  function setReservedRate(uint256 _reservedRate) external {
    if (msg.sender == IJBProjects(directory.projects()).ownerOf(projectId))
      revert setReservedRate_unauth();
    emit NewReservedRate(reservedRate, _reservedRate);
    reservedRate = _reservedRate;
  }

  function setSwappedPortion(uint256 _portion) external {
    if (msg.sender == IJBProjects(directory.projects()).ownerOf(projectId))
      revert setSwappedPortion_unauth();
    emit NewSwappedPortion(swappedPortion, _portion);
    swappedPortion = _portion;
  }
}
