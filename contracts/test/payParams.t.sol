// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '../interfaces/external/IWETH9.sol';
import './helpers/TestBaseWorkflow.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBController/1.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBFundingCycleDataSource.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBOperatable.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBReconfigurationBufferBallot.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBRedemptionDelegate.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBPayoutRedemptionPaymentTerminal.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBSingleTokenPaymentTerminalStore.sol';
import '@jbx-protocol-v2/contracts/interfaces/IJBToken.sol';
import '@jbx-protocol-v2/contracts/libraries/JBConstants.sol';
import '@jbx-protocol-v2/contracts/libraries/JBCurrencies.sol';
import '@jbx-protocol-v2/contracts/libraries/JBFundingCycleMetadataResolver.sol';
import '@jbx-protocol-v2/contracts/libraries/JBOperations.sol';
import '@jbx-protocol-v2/contracts/libraries/JBTokens.sol';
import '@jbx-protocol-v2/contracts/structs/JBFundingCycle.sol';

import '@paulrberg/contracts/math/PRBMath.sol';
import '@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol';

import '../DataSourceDelegate.sol';

contract TestPayParams is TestBaseWorkflow {
  using JBFundingCycleMetadataResolver for JBFundingCycle;
  JBController controller;
  JBProjectMetadata _projectMetadata;
  JBFundingCycleData _data;
  JBFundingCycleData _dataReconfiguration;
  JBFundingCycleData _dataWithoutBallot;
  JBFundingCycleMetadata _metadata;
  JBGroupedSplits[] _groupedSplits; // Default empty
  JBFundAccessConstraints[] _fundAccessConstraints; // Default empty
  IJBPaymentTerminal[] _terminals; // Default empty
  uint256 _projectId;

  uint256 reservedRate = 4500;
  uint256 weight = 10000 * 10**18;
  DataSourceDelegate _delegate;

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

  function setUp() public override {
    evm.label(address(pool), 'uniswapPool');
    evm.label(address(weth), '$WETH');
    evm.label(address(jbx), '$JBX');

    evm.etch(address(pool), '0x69');
    evm.etch(address(weth), '0x69');
    evm.etch(address(jbx), '0x69');

    super.setUp();

    controller = jbController();

    _delegate = new DataSourceDelegate(jbETHPaymentTerminal(), reservedRate);

    _projectMetadata = JBProjectMetadata({content: 'myIPFSHash', domain: 1});

    _data = JBFundingCycleData({
      duration: 6 days,
      weight: weight,
      discountRate: 0,
      ballot: IJBReconfigurationBufferBallot(address(0))
    });

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({allowSetTerminals: false, allowSetController: false}),
      reservedRate: 10000,
      redemptionRate: 5000,
      ballotRedemptionRate: 0,
      pausePay: false,
      pauseDistributions: false,
      pauseRedeem: false,
      pauseBurn: false,
      allowMinting: true,
      allowChangeToken: false,
      allowTerminalMigration: false,
      allowControllerMigration: false,
      holdFees: false,
      useTotalOverflowForRedemptions: false,
      useDataSourceForPay: true,
      useDataSourceForRedeem: false,
      dataSource: address(_delegate)
    });

    _fundAccessConstraints.push(
      JBFundAccessConstraints({
        terminal: jbETHPaymentTerminal(),
        token: jbLibraries().ETHToken(),
        distributionLimit: 0,
        overflowAllowance: type(uint232).max,
        distributionLimitCurrency: 1, // Currency = ETH
        overflowAllowanceCurrency: 1
      })
    );

    // Grant overflow allowance
    uint256[] memory permissionIndex = new uint256[](1);
    permissionIndex[0] = JBOperations.USE_ALLOWANCE;

    evm.prank(multisig());
    jbOperatorStore().setOperator(
      JBOperatorData({operator: address(_delegate), domain: 1, permissionIndexes: permissionIndex})
    );

    // Set terminal as feeless
    evm.prank(multisig());
    jbETHPaymentTerminal().setFeelessAddress(address(_delegate), true);

    _terminals = [jbETHPaymentTerminal()];

    _projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );
  }

  // If a reserved rate < JBConstants.MAX_RESERVED_RATE is used in the current funding cycle, do not use the data source/delegate logic
  function testDatasourceDelegateNormalBehaviorWithNonMaxReservedRate() public {
    uint256 payAmountInWei = 10 ether;

    _metadata = JBFundingCycleMetadata({
      global: JBGlobalFundingCycleMetadata({allowSetTerminals: false, allowSetController: false}),
      reservedRate: reservedRate,
      redemptionRate: 5000,
      ballotRedemptionRate: 0,
      pausePay: false,
      pauseDistributions: false,
      pauseRedeem: false,
      pauseBurn: false,
      allowMinting: true,
      allowChangeToken: false,
      allowTerminalMigration: false,
      allowControllerMigration: false,
      holdFees: false,
      useTotalOverflowForRedemptions: false,
      useDataSourceForPay: true,
      useDataSourceForRedeem: false,
      dataSource: address(_delegate)
    });

    _terminals = [jbETHPaymentTerminal()];

    _projectId = controller.launchProjectFor(
      multisig(),
      _projectMetadata,
      _data,
      _metadata,
      0, // Start asap
      _groupedSplits,
      _fundAccessConstraints,
      _terminals,
      ''
    );

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      1,
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      new bytes(0)
    );

    uint256 totalMinted = PRBMath.mulDiv(payAmountInWei, weight, 10**18);
    uint256 amountBeneficiary = (totalMinted * (JBConstants.MAX_RESERVED_RATE - reservedRate)) /
      JBConstants.MAX_RESERVED_RATE;
    uint256 amountReserved = totalMinted - amountBeneficiary;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountBeneficiary);
    assertEq(controller.reservedTokenBalanceOf(_projectId, reservedRate), amountReserved);
  }

  // If minting gives a higher amount of project token, mint should be used with proper token distribution to beneficiary and reserved token
  function testDatasourceDelegateMintIfQuoteIsHigher() public {
    uint256 payAmountInWei = 10 ether;

    // Correspond to an amount out of 9999000099990000999 -> mint returns more (10E18)
    uint256[] memory _ticks = new uint256[](2);
    _ticks[0] = 10;
    _ticks[1] = 130;

    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolDerivedState.observe.selector),
      abi.encode(_ticks, _ticks) // Second returned value is dropped in oracle lib
    );

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      0, // Cannot be used in this setting
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      new bytes(0)
    );

    // Delegate is deployed using reservedRate
    uint256 amountBeneficiary = PRBMath.mulDiv(payAmountInWei, weight, 10**18);
    uint256 amountReserved = ((amountBeneficiary * JBConstants.MAX_RESERVED_RATE) /
      (JBConstants.MAX_RESERVED_RATE - reservedRate)) - amountBeneficiary;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountBeneficiary);

    assertEq(
      controller.reservedTokenBalanceOf(_projectId, JBConstants.MAX_RESERVED_RATE),
      (amountReserved / 10) * 10 // Last wei rounding
    );
  }

  // If swapping gives a higher amount, swap should be used, with proper token distribution to beneficiary and reserved token
  function testDatasourceDelegateSwapIfQuoteIsHigher() public {
    uint256 payAmountInWei = 10 ether;
    uint256 quoteOnUniswap = 4632021042254268047555904;

    evm.etch(address(pool), '0x69');

    // Correspond to an amount out of 4632021042254268047555904
    uint256[] memory _ticks = new uint256[](2);
    _ticks[0] = 15000000;
    _ticks[1] = 1;

    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolDerivedState.observe.selector),
      abi.encode(_ticks, _ticks) // Second returned value is dropped in oracle lib
    );

    // Mock the swap returned value, which is the amount of token transfered (negative = exact amount)
    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolActions.swap.selector),
      abi.encode(-int256(quoteOnUniswap), 0)
    );

    jbETHPaymentTerminal().addToBalanceOf{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      jbLibraries().ETHToken(),
      '',
      bytes('')
    );

    // Trick the balance post-swap
    evm.prank(multisig());

    jbController().mintTokensOf(_projectId, quoteOnUniswap, address(_delegate), '', false, false);

    // Mock the jbx transfer to the beneficiary - same logic as in delegate to avoid rounding errors
    uint256 reservedAmount = PRBMath.mulDiv(
      quoteOnUniswap,
      reservedRate,
      JBConstants.MAX_RESERVED_RATE
    );

    uint256 nonReservedAmount = quoteOnUniswap - reservedAmount;

    evm.mockCall(
      address(jbx),
      abi.encodeWithSelector(
        IJBToken.transfer.selector,
        _projectId,
        beneficiary(),
        nonReservedAmount
      ),
      abi.encode(true)
    );

    // Test: transfering the right amount to beneficiary
    evm.expectCall(
      address(jbx),
      abi.encodeWithSelector(
        IJBToken.transfer.selector,
        _projectId,
        beneficiary(),
        nonReservedAmount
      )
    );

    jbETHPaymentTerminal().pay{value: payAmountInWei}(
      _projectId,
      payAmountInWei,
      address(0),
      beneficiary(),
      /* _minReturnedTokens */
      0,
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      new bytes(0)
    );

    assertEq(
      controller.reservedTokenBalanceOf(_projectId, JBConstants.MAX_RESERVED_RATE),
      reservedAmount // Last wei rounding
    );
  }

  // Callback should be callable by the pool and proceed to weth transfer if deviation from twap is within maximum allowed values
  function testCallback() public {
    uint256 twap = 100;

    evm.mockCall(address(weth), abi.encodeWithSelector(IWETH9.deposit.selector), abi.encode(true));

    evm.mockCall(
      address(weth),
      abi.encodeWithSelector(IERC20.transfer.selector, address(pool), 1000),
      abi.encode(true)
    );

    // jbx address < weth address
    evm.prank(address(pool));
    _delegate.uniswapV3SwapCallback(-int256(100), int256(1000), abi.encode(twap));
  }

  // The callback can't be called by another address than the Uniswap V3 pool
  function testCallbackUnauthRevert(address _caller) public {
    evm.assume(_caller != address(pool));
    uint256 twap = 100;

    evm.prank(_caller);
    evm.expectRevert(abi.encodeWithSignature('Callback_unauth()'));
    _delegate.uniswapV3SwapCallback(int256(100), int256(100), abi.encode(twap));
  }

  // The callback should revert if the deviation between spot and twap is more than 1%
  function testCallbackSlippageRevert(int96 amount0, uint96 _twap) public {
    int128 twap = int128(int96(_twap));

    // be at more or less than 1% twap deviation
    evm.assume(amount0 > (twap * 101) / 100 || amount0 < (twap * 99) / 100);

    evm.prank(address(pool));
    evm.expectRevert(abi.encodeWithSignature('Callback_slippage()'));
    _delegate.uniswapV3SwapCallback(int256(amount0), int256(1), abi.encode(_twap));
  }
}
