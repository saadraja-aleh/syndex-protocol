// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {Utils} from "./Utils.sol";

import "@uniswap/core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ISynDex} from "../src/interfaces/ISynDex.sol";
import {IFeePool} from "../src/interfaces/IFeePool.sol";
import {ISwapRouter} from "../src/interfaces/ISwapRouter.sol";
import {IMixinResolver} from "../src/interfaces/IMixinResolver.sol";
import {IAggregationRouterV4} from "../src/interfaces/IAggregationRouterV4.sol";

import {Depot} from "../src/contracts/Depot.sol";
import {Proxy} from "../src/contracts/Proxy.sol";
import {Issuer} from "../src/contracts/Issuer.sol";
import {FeePool} from "../src/contracts/FeePool.sol";
import {Token} from "../src/contracts/test/Token.sol";
import {Proxyable} from "../src/contracts/Proxyable.sol";
import {SynDex} from "../src/contracts/SynDex.sol";
import {DebtCache} from "../src/contracts/DebtCache.sol";
import {Exchanger} from "../src/contracts/Exchanger.sol";
import {SynthUtil} from "../src/contracts/SynthUtil.sol";
import {SynthSwap} from "../src/contracts/Synthswap.sol";
import {ProxyERC20} from "../src/contracts/ProxyERC20.sol";
import {Liquidator} from "../src/contracts/Liquidator.sol";
import {TokenState} from "../src/contracts/TokenState.sol";
import {FeePoolState} from "../src/contracts/FeePoolState.sol";
import {EtherWrapper} from "../src/contracts/EtherWrapper.sol";
import {RewardEscrow} from "../src/contracts/RewardEscrow.sol";
import {SystemStatus} from "../src/contracts/SystemStatus.sol";
import {CollateralEth} from "../src/contracts/CollateralEth.sol";
import {ExchangeRates} from "../src/contracts/ExchangeRates.sol";
import {ExchangeState} from "../src/contracts/ExchangeState.sol";
import {SynthRedeemer} from "../src/contracts/SynthRedeemer.sol";
import {SynDexState} from "../src/contracts/SynDexState.sol";
import {WrapperFactory} from "../src/contracts/WrapperFactory.sol";
import {RewardEscrowV2} from "../src/contracts/RewardEscrowV2.sol";
import {TradingRewards} from "../src/contracts/TradingRewards.sol";
import {CollateralUtil} from "../src/contracts/CollateralUtil.sol";
import {EternalStorage} from "../src/contracts/EternalStorage.sol";
import {SystemSettings} from "../src/contracts/SystemSettings.sol";
import {CircuitBreaker} from "../src/contracts/CircuitBreaker.sol";
import {AggregatorSynth} from "../src/contracts/AggregatorSynth.sol";
import {CollateralErc20} from "../src/contracts/CollateralErc20.sol";
import {AddressResolver} from "../src/contracts/AddressResolver.sol";
import {FlexibleStorage} from "../src/contracts/FlexibleStorage.sol";
import {LegacyTokenState} from "../src/contracts/LegacyTokenState.sol";
import {DelegateApprovals} from "../src/contracts/DelegateApprovals.sol";
import {CollateralManager} from "../src/contracts/CollateralManager.sol";
import {LiquidatorRewards} from "../src/contracts/LiquidatorRewards.sol";
import {SynDexDebtShare} from "../src/contracts/SynDexDebtShare.sol";
import {RewardsDistribution} from "../src/contracts/RewardsDistribution.sol";
import {AggregatorDebtRatio} from "../src/contracts/AggregatorDebtRatio.sol";
import {MultiCollateralSynth} from "../src/contracts/MultiCollateralSynth.sol";
import {AggregatorCollateral} from "../src/contracts/AggregatorCollateral.sol";
import {FuturesMarketManager} from "../src/contracts/FuturesMarketManager.sol";
import {RewardEscrowV2Frozen} from "../src/contracts/RewardEscrowV2Frozen.sol";
import {RewardEscrowV2Storage} from "../src/contracts/RewardEscrowV2Storage.sol";
import {FeePoolEternalStorage} from "../src/contracts/FeePoolEternalStorage.sol";
import {CollateralManagerState} from "../src/contracts/CollateralManagerState.sol";
import {AggregatorIssuedSynths} from "../src/contracts/AggregatorIssuedSynths.sol";
import {DirectIntegrationManager} from "../src/contracts/DirectIntegrationManager.sol";

contract Setup is Test, Utils {
    address public owner = vm.addr(1);
    address public user1 = vm.addr(2);
    address public user2 = vm.addr(3);
    address public user3 = vm.addr(4);
    address public user4 = vm.addr(5);
    address public user5 = vm.addr(6);
    address public user6 = vm.addr(7);
    address public user7 = vm.addr(8);
    address public user8 = vm.addr(9);
    address public treasury = vm.addr(10);
    address public reserveAddr = vm.addr(11);
    address public stakingAddr = vm.addr(12);

    address public WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapV2Factory factory =
        IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    IUniswapV2Router02 router =
        IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IAggregationRouterV4 routerV4 =
        IAggregationRouterV4(0x1111111254fb6c44bAC0beD2854e76F90643097d);

    ISwapRouter swapRouter =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    bytes32[] public names;
    address[] public addresses;

    Depot public depot;
    Token public token;
    Issuer public issuer;
    SynDex public syndex;
    FeePool public feePool;
    Proxy public proxyFeePool;
    DebtCache public debtCache;
    Exchanger public exchanger;
    SynthSwap public synthSwap;
    ProxyERC20 public proxySFCX;
    SynthUtil public synthUtil;
    ProxyERC20 public proxycfUSD;
    ProxyERC20 public proxycfETH;
    Liquidator public liquidator;
    FeePoolState public feePoolState;
    EtherWrapper public etherWrapper;
    RewardEscrow public rewardEscrow;
    TokenState public tokenStatecfUSD;
    TokenState public tokenStatecfETH;
    SystemStatus public systemStatus;
    CollateralEth public collateralETH;
    ExchangeState public exchangeState;
    SynthRedeemer public synthRedeemer;
    ExchangeRates public exchangeRates;
    SynDexState public syndexState;
    TradingRewards public tradingRewards;
    RewardEscrowV2 public rewardEscrowV2;
    CollateralUtil public collateralUtil;
    EternalStorage public eternalStorage;
    SystemSettings public systemSettings;
    CircuitBreaker public circuitBreaker;
    WrapperFactory public wrapperFactory;
    LegacyTokenState public tokenStateSFCX;
    MultiCollateralSynth public synthcfUSD;
    MultiCollateralSynth public synthcfETH;
    FlexibleStorage public flexibleStorage;
    AddressResolver public addressResolver;
    CollateralErc20 public collateralErc20;
    DelegateApprovals public delegateApprovals;
    CollateralManager public collateralManager;
    LiquidatorRewards public liquidatorRewards;
    SynDexDebtShare public syndexDebtShare;
    RewardsDistribution public rewardsDistribution;
    RewardEscrowV2Frozen public rewardEscrowV2Frozen;
    FuturesMarketManager public futuresMarketManager;
    RewardEscrowV2Storage public rewardEscrowV2Storage;
    FeePoolEternalStorage public feePoolEternalStorage;
    CollateralManagerState public collateralManagerState;
    DirectIntegrationManager public directIntegrationManager;

    AggregatorSynth public aggregatorSynth;
    AggregatorDebtRatio public aggregatorDebtRatio;
    AggregatorCollateral public aggregatorCollateral;
    AggregatorIssuedSynths public aggregatorIssuedSynths;

    function setUp() public virtual {
        deal(owner, 100 ether);
        deal(user1, 100 ether);
        deal(user2, 100 ether);
        deal(user3, 100 ether);
        deal(user6, 100 ether);
        deal(user7, 100 ether);
        deal(user8, 100 ether);

        deal(WETH, owner, 100 ether);
        deal(WETH, user1, 100 ether);
        deal(WETH, user2, 100 ether);
        deal(WETH, user3, 100 ether);
        deal(WETH, user6, 100 ether);
        deal(WETH, user7, 100 ether);
        deal(WETH, user8, 100 ether);

        vm.startPrank(owner); // OWNER

        // // ------------------------------
        // DEPLOYMENTS ---
        // // ------------------------------

        addressResolver = new AddressResolver(owner);

        token = new Token("My Token", "TKN", owner, 100_000_000 ether);
        synthUtil = new SynthUtil(address(addressResolver));
        collateralUtil = new CollateralUtil(address(addressResolver));
        collateralManagerState = new CollateralManagerState(owner, owner);
        collateralManager = new CollateralManager(
            address(collateralManagerState),
            owner,
            address(addressResolver),
            75000000 ether,
            0.2 ether,
            0,
            0
        );
        collateralETH = new CollateralEth(
            owner,
            address(collateralManager),
            address(addressResolver),
            "cfETH",
            1.5 ether, // 100 / 150, 150%
            0.1 ether
        );
        collateralErc20 = new CollateralErc20(
            owner,
            address(collateralManager),
            address(addressResolver),
            "SMX",
            1.5 ether, // 100 / 150, 150%
            0.1 ether,
            address(token),
            18
        );

        proxyFeePool = new Proxy(owner);
        proxySFCX = new ProxyERC20(owner);
        proxycfUSD = new ProxyERC20(owner);
        proxycfETH = new ProxyERC20(owner);
        systemStatus = new SystemStatus(owner);
        issuer = new Issuer(owner, address(addressResolver));
        debtCache = new DebtCache(owner, address(addressResolver));
        exchanger = new Exchanger(owner, address(addressResolver));
        synthRedeemer = new SynthRedeemer(address(addressResolver));
        liquidator = new Liquidator(owner, address(addressResolver));
        exchangeState = new ExchangeState(owner, address(exchanger));
        flexibleStorage = new FlexibleStorage(address(addressResolver));
        systemSettings = new SystemSettings(owner, address(addressResolver));
        circuitBreaker = new CircuitBreaker(owner, address(addressResolver));
        syndexState = new SynDexState(owner, address(syndex));
        tokenStateSFCX = new LegacyTokenState(owner, address(syndex));
        tokenStatecfUSD = new TokenState(owner, address(synthcfUSD));
        tokenStatecfETH = new TokenState(owner, address(synthcfETH));
        wrapperFactory = new WrapperFactory(owner, address(addressResolver));
        depot = new Depot(owner, payable(treasury), address(addressResolver));
        directIntegrationManager = new DirectIntegrationManager(
            owner,
            address(addressResolver)
        );
        feePool = new FeePool(
            payable(address(proxyFeePool)),
            owner,
            address(addressResolver)
        );
        feePoolEternalStorage = new FeePoolEternalStorage(
            owner,
            address(feePool)
        );
        rewardEscrow = new RewardEscrow(
            owner,
            address(syndex),
            address(feePool)
        );
        etherWrapper = new EtherWrapper(
            owner,
            address(addressResolver),
            payable(WETH)
        );
        futuresMarketManager = new FuturesMarketManager(
            owner,
            address(addressResolver)
        );
        liquidatorRewards = new LiquidatorRewards(
            owner,
            address(addressResolver)
        );
        syndexDebtShare = new SynDexDebtShare(owner, address(addressResolver));
        syndex = new SynDex(
            payable(address(proxySFCX)),
            address(tokenStateSFCX),
            owner,
            0,
            address(addressResolver)
        );
        synthcfUSD = new MultiCollateralSynth(
            payable(address(proxycfUSD)),
            address(tokenStatecfUSD),
            "SynthcfUSD",
            "cfUSD",
            owner,
            "cfUSD",
            0,
            address(addressResolver)
        );
        synthcfETH = new MultiCollateralSynth(
            payable(address(proxycfETH)),
            address(tokenStatecfETH),
            "SynthcfETH",
            "cfETH",
            owner,
            "cfETH",
            0,
            address(addressResolver)
        );
        feePoolState = new FeePoolState(owner, address(feePool));
        rewardEscrowV2 = new RewardEscrowV2(owner, address(addressResolver));
        rewardEscrowV2Storage = new RewardEscrowV2Storage(
            owner,
            address(rewardEscrowV2)
        );
        rewardsDistribution = new RewardsDistribution(
            owner,
            address(syndex),
            address(proxySFCX),
            address(rewardEscrowV2),
            address(proxyFeePool)
        );
        rewardEscrowV2Frozen = new RewardEscrowV2Frozen(
            owner,
            address(addressResolver)
        );
        eternalStorage = new EternalStorage(owner, address(synthcfUSD));
        delegateApprovals = new DelegateApprovals(
            owner,
            address(eternalStorage)
        );
        synthSwap = new SynthSwap(
            address(proxycfUSD),
            address(swapRouter), // routerV4
            address(addressResolver),
            owner, // volumeRewards
            treasury
        );
        tradingRewards = new TradingRewards(
            owner,
            user5, // periodController
            address(addressResolver)
        );

        exchangeRates = new ExchangeRates(owner, address(addressResolver));

        aggregatorSynth = new AggregatorSynth(
            "",
            1 * 10 ** 8,
            address(addressResolver)
        );
        aggregatorDebtRatio = new AggregatorDebtRatio(addressResolver);
        aggregatorIssuedSynths = new AggregatorIssuedSynths(addressResolver);
        aggregatorCollateral = new AggregatorCollateral(
            address(addressResolver)
        );

        // // ------------------------------
        // RESOLVER ADDRESSES ---
        // // ------------------------------

        uint8 count = 0;

        names.push("AddressResolver");
        addresses.push(address(addressResolver));
        count++;
        names.push("ProxySFCX");
        addresses.push(address(proxySFCX));
        count++;
        names.push("SystemStatus");
        addresses.push(address(systemStatus));
        count++;
        names.push("TokenStateSFCX");
        addresses.push(address(tokenStateSFCX));
        count++;
        names.push("TokenStatecfUSD");
        addresses.push(address(tokenStatecfUSD));
        count++;
        names.push("ext:AggregatorIssuedSynths");
        addresses.push(address(aggregatorIssuedSynths));
        count++;
        names.push("ext:AggregatorDebtRatio");
        addresses.push(address(aggregatorDebtRatio));
        count++;
        names.push("FlexibleStorage");
        addresses.push(address(flexibleStorage));
        count++;
        names.push("ExchangeState");
        addresses.push(address(exchangeState));
        count++;
        names.push("DelegateApprovals");
        addresses.push(address(delegateApprovals));
        count++;
        names.push("RewardsDistribution");
        addresses.push(address(rewardsDistribution));
        count++;
        names.push("RewardEscrowV2Storage");
        addresses.push(address(rewardEscrowV2Storage));
        count++;
        names.push("RewardEscrow");
        addresses.push(address(rewardEscrow));
        count++;
        names.push("FeePoolEternalStorage");
        addresses.push(address(feePoolEternalStorage));
        count++;
        names.push("SynDexBridgeToOptimism");
        addresses.push(owner);
        count++;
        // ---
        names.push("Depot");
        addresses.push(address(depot));
        names.push("DirectIntegrationManager");
        addresses.push(address(directIntegrationManager));
        names.push("RewardEscrowV2");
        addresses.push(address(rewardEscrowV2));
        names.push("ExchangeRates");
        addresses.push(address(exchangeRates));
        names.push("Issuer");
        addresses.push(address(issuer));
        names.push("LiquidatorRewards");
        addresses.push(address(liquidatorRewards));
        names.push("SynDexDebtShare");
        addresses.push(address(syndexDebtShare));
        names.push("SynDex");
        addresses.push(address(syndex));
        names.push("SynthcfUSD");
        addresses.push(address(synthcfUSD));
        names.push("SynthcfETH");
        addresses.push(address(synthcfETH));
        names.push("FeePool");
        addresses.push(address(feePool));
        names.push("DebtCache");
        addresses.push(address(debtCache));
        names.push("CircuitBreaker");
        addresses.push(address(circuitBreaker));
        names.push("SystemSettings");
        addresses.push(address(systemSettings));
        names.push("Exchanger");
        addresses.push(address(exchanger));
        names.push("Liquidator");
        addresses.push(address(liquidator));
        names.push("SynthRedeemer");
        addresses.push(address(synthRedeemer));
        names.push("CollateralManager");
        addresses.push(address(collateralManager));
        names.push("CollateralETH");
        addresses.push(address(collateralETH));
        names.push("CollateralErc20");
        addresses.push(address(collateralErc20));
        names.push("CollateralUtil");
        addresses.push(address(collateralUtil));
        names.push("FuturesMarketManager");
        addresses.push(address(futuresMarketManager));
        names.push("EtherWrapper");
        addresses.push(address(etherWrapper));
        names.push("WrapperFactory");
        addresses.push(address(wrapperFactory));
        names.push("TradingRewards");
        addresses.push(address(tradingRewards));

        addressResolver.loadAddresses(names, addresses);
        for (uint i = count; i < addresses.length; i++) {
            IMixinResolver(addresses[i]).refreshCache();
        }

        // // ---------------------------------------------------------------------
        // // ---------------------------------------------------------------------
        // // ---------------------------------------------------------------------

        bytes32[] memory _synthNamesInResolver = new bytes32[](2);
        bytes32[] memory _synthKeys = new bytes32[](2);
        _synthNamesInResolver[0] = "SynthcfUSD";
        _synthKeys[0] = "cfUSD";
        _synthNamesInResolver[1] = "SynthcfETH";
        _synthKeys[1] = "cfETH";
        collateralETH.addSynths(_synthNamesInResolver, _synthKeys);
        collateralErc20.addSynths(_synthNamesInResolver, _synthKeys);
        collateralManager.addSynths(_synthNamesInResolver, _synthKeys);

        address[] memory collateralAddresses = new address[](2);
        collateralAddresses[0] = address(collateralETH);
        collateralAddresses[1] = address(collateralErc20);
        collateralManager.addCollaterals(collateralAddresses);

        issuer.addSynth(address(synthcfUSD));
        issuer.addSynth(address(synthcfETH));

        proxySFCX.updateTarget(address(syndex));
        proxycfUSD.updateTarget(address(synthcfUSD));
        proxycfETH.updateTarget(address(synthcfETH));
        proxyFeePool.updateTarget(address(feePool));

        syndexState.linkContract(address(syndex));
        tokenStateSFCX.linkContract(address(syndex));
        tokenStatecfUSD.linkContract(address(synthcfUSD));
        tokenStatecfETH.linkContract(address(synthcfETH));
        collateralManagerState.linkContract(address(collateralManager));

        rewardEscrowV2Storage.setFallbackRewardEscrow(
            address(rewardEscrowV2Frozen)
        );

        exchangeRates.addAggregator("SMX", address(aggregatorSynth));
        exchangeRates.addAggregator("cfETH", address(aggregatorSynth));
        exchangeRates.addAggregator("SFCX", address(aggregatorCollateral));

        // 200000000000000000, 0.33  = 100 / 300%
        // 625000000000000000, 0.66  = 100 / 150%
        // 100000000000000000, 0.1   = 10% / 100
        // 600000000000000000, 0.6   = 60% / 100
        // 500000000000000000, 0.5   = 50% / 100

        systemSettings.setIssuanceRatio(0.33 ether);
        systemSettings.setLiquidationRatio(0.66 ether);
        systemSettings.updateSfcxLiquidationPenalty(0.6 ether); // forced
        systemSettings.updateSelfLiquidationPenalty(0.5 ether);
        systemSettings.updateLiquidationDelay(28800);
        systemSettings.updateRateStalePeriod(86400);
        systemSettings.updatePriceDeviationThreshold(100 ether);

        systemSettings.updateAtomicTwapWindow(1800);
        systemSettings.updateAtomicMaxVolumePerBlock(200000 ether);
        systemSettings.updateExchangeMaxDynamicFee(0.1 ether);
        systemSettings.updateExchangeDynamicFeeRounds(6);
        systemSettings.updateExchangeDynamicFeeThreshold(0.0025 ether);
        systemSettings.updateExchangeDynamicFeeWeightDecay(0.95 ether);
        systemSettings.toggleTradingRewards(true);
        systemSettings.setFeePeriodDuration(7 days);
        systemSettings.setMinimumStakeTime(7 days);

        bytes32[] memory synthKeys = new bytes32[](2);
        uint256[] memory exchangeFeeRates = new uint256[](2);
        synthKeys[0] = "cfUSD";
        synthKeys[1] = "cfETH";
        exchangeFeeRates[0] = 0.001 ether;
        exchangeFeeRates[1] = 0.001 ether; // 0.0035
        systemSettings.updateExchangeFeeRateForSynths(
            synthKeys,
            exchangeFeeRates
        );

        factory.createPair(address(proxySFCX), WETH);
        address pairSFCXWETH = factory.getPair(address(proxySFCX), WETH);

        syndex.mint(owner, 1_000_000 ether);
        syndex.setReserveAddress(reserveAddr);
        syndex.setPool(pairSFCXWETH, true);
        syndex.setTrade(true);

        proxySFCX.transfer(user1, 5 ether);
        proxySFCX.transfer(user2, 10 ether);
        proxySFCX.transfer(user3, 15 ether);
        proxySFCX.transfer(user4, 1000 ether);
        proxySFCX.transfer(user5, 5000 ether);
        proxySFCX.transfer(user6, 1000 ether);
        proxySFCX.transfer(user7, 5000 ether);
        proxySFCX.transfer(user8, 5000 ether);
        proxySFCX.transfer(reserveAddr, 200000 ether);

        vm.stopPrank(); // OWNER

        vm.startPrank(address(reserveAddr));
        proxySFCX.approve(user8, 1_000_000_000 ether);
        vm.stopPrank();
    }
}
