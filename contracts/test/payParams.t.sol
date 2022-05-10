// SPDX-License-Identifier: MIT
pragma solidity 0.8.6;

import '../interfaces/external/IWETH9.sol';
import './helpers/TestBaseWorkflow.sol';

import '@jbx-protocol-v2/contracts/interfaces/IJBController.sol';
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

  uint256 reservedRate = 4000;
  uint256 weight = 10000 * 10**18;
  DataSourceDelegate _delegate;

  IWETH9 private constant weth = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  IJBToken private constant jbx = IJBToken(0x3abF2A4f8452cCC2CF7b4C1e4663147600646f66);

  IUniswapV3Pool private constant pool = IUniswapV3Pool(0x48598Ff1Cee7b4d31f8f9050C2bbAE98e17E6b17);

  function setUp() public override {
    evm.label(address(pool), 'uniswapPool');
    evm.label(address(weth), '$WETH');
    evm.label(address(jbx), '$JBX');

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

  function testPayParamsNormalBehaviorWithNonMaxReservedRate() public {
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

    uint256 amountOutTheory = (PRBMath.mulDiv(payAmountInWei, weight, 10**18) * reservedRate) /
      JBConstants.MAX_RESERVED_RATE;

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountOutTheory);
  }

  function testPayParamsMint() public {
    uint256 payAmountInWei = 10 ether;

    evm.etch(address(pool), '0x69');

    // Correspond to an amount out of 9999000099990000999
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
      0,
      /* _preferClaimedTokens */
      false,
      /* _memo */
      'Take my money!',
      /* _delegateMetadata */
      new bytes(0)
    );

    // Delegate is deployed using reservedRate
    uint256 amountOutTheory = PRBMath.mulDiv(payAmountInWei, weight, 10**18);

    assertEq(jbTokenStore().balanceOf(beneficiary(), _projectId), amountOutTheory);

    assertEq(
      controller.reservedTokenBalanceOf(_projectId, reservedRate),
      (amountOutTheory * reservedRate) / 10000
    );
  }

  function testPayParamsSwap() public {
    uint256 payAmountInWei = 10 ether;

    evm.etch(address(pool), '0x69');

    // Correspond to an amount out of 2681696392884049922311550
    uint256[] memory _ticks = new uint256[](2);
    _ticks[0] = 15000000;
    _ticks[1] = 1;

    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolDerivedState.observe.selector),
      abi.encode(_ticks, _ticks) // Second returned value is dropped in oracle lib
    );

    evm.mockCall(
      address(pool),
      abi.encodeWithSelector(IUniswapV3PoolActions.swap.selector),
      abi.encode(0, 0)
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
  }
}
