// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ISynthSwap.sol";
import "../interfaces/ISynDex.sol";
import "../interfaces/IAddressResolver.sol";
import "../interfaces/IAggregationExecutor.sol";
import {ISwapRouter} from "../interfaces/ISwapRouter.sol";

import "../libraries/RevertReasonParser.sol";

/// @title system to swap synths to/from many erc20 tokens
/// @dev IAggregationRouterV4 relies on calldata generated off-chain
contract SynthSwap is ISynthSwap, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 immutable cfUSD;
    ISwapRouter immutable router; // IAggregationRouterV4
    IAddressResolver immutable addressResolver;
    address immutable volumeRewards;
    address immutable treasury;

    address constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    bytes32 private constant CONTRACT_SYNDEX = "SynDex";
    bytes32 private constant cfUSD_CURRENCY_KEY = "cfUSD";
    bytes32 private constant TRACKING_CODE = "SFCX";

    event SwapInto(address indexed from, uint amountReceived);
    event SwapOutOf(address indexed from, uint amountReceived);
    event Received(address from, uint amountReceived);

    constructor(
        address _cfUSD,
        address _router,
        address _addressResolver,
        address _volumeRewards,
        address _treasury
    ) Ownable(msg.sender) {
        cfUSD = IERC20(_cfUSD);
        router = ISwapRouter(_router); // IAggregationRouterV4
        addressResolver = IAddressResolver(_addressResolver);
        volumeRewards = _volumeRewards;
        treasury = _treasury;
    }

    //////////////////////////////////////
    ///////// EXTERNAL FUNCTIONS /////////
    //////////////////////////////////////

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // /// @inheritdoc ISynthSwap
    // function swapInto(
    //     bytes32 _destSynthCurrencyKey,
    //     bytes calldata _data
    // ) external payable override returns (uint) {
    //     (uint amountOut, ) = swapOn1inch(_data, false);

    //     // if destination synth is NOT cfUSD, swap on SynDex is necessary
    //     if (_destSynthCurrencyKey != cfUSD_CURRENCY_KEY) {
    //         amountOut = swapOnSynDex(
    //             amountOut,
    //             cfUSD_CURRENCY_KEY,
    //             _destSynthCurrencyKey
    //         );
    //     }

    //     address destSynthAddress = proxyForSynth(
    //         addressResolver.getSynth(_destSynthCurrencyKey)
    //     );
    //     IERC20(destSynthAddress).safeTransfer(msg.sender, amountOut);

    //     emit SwapInto(msg.sender, amountOut);
    //     return amountOut;
    // }

    // /// @inheritdoc ISynthSwap
    // function swapOutOf(
    //     bytes32 _sourceSynthCurrencyKey,
    //     uint _sourceAmount,
    //     bytes calldata _data
    // ) external override nonReentrant returns (uint) {
    //     // transfer synth to this contract
    //     address sourceSynthAddress = proxyForSynth(
    //         addressResolver.getSynth(_sourceSynthCurrencyKey)
    //     );
    //     IERC20(sourceSynthAddress).safeTransferFrom(
    //         msg.sender,
    //         address(this),
    //         _sourceAmount
    //     );

    //     // if source synth is NOT cfUSD, swap on SynDex is necessary
    //     if (_sourceSynthCurrencyKey != cfUSD_CURRENCY_KEY) {
    //         swapOnSynDex(
    //             _sourceAmount,
    //             _sourceSynthCurrencyKey,
    //             cfUSD_CURRENCY_KEY
    //         );
    //     }

    //     (uint amountOut, address dstToken) = swapOn1inch(_data, true);

    //     if (dstToken == ETH_ADDRESS) {
    //         (bool success, bytes memory result) = msg.sender.call{
    //             value: amountOut
    //         }("");
    //         if (!success) {
    //             revert(RevertReasonParser.parse(result, "callBytes failed: "));
    //         }
    //     } else {
    //         IERC20(dstToken).safeTransfer(msg.sender, amountOut);
    //     }

    //     emit SwapOutOf(msg.sender, amountOut);

    //     // any remaining cfUSD in contract should be transferred to treasury
    //     uint remainingBalanceCFUSD = cfUSD.balanceOf(address(this));
    //     if (remainingBalanceCFUSD > 0) {
    //         cfUSD.safeTransfer(treasury, remainingBalanceCFUSD);
    //     }

    //     return amountOut;
    // }

    /// @inheritdoc ISynthSwap
    function uniswapSwapInto(
        bytes32 _destSynthCurrencyKey,
        address _sourceTokenAddress,
        uint _amount,
        bytes calldata _data
    ) external payable override returns (uint) {
        // if not swapping from ETH, transfer source token to contract and approve spending
        if (_sourceTokenAddress != ETH_ADDRESS) {
            IERC20(_sourceTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
            IERC20(_sourceTokenAddress).approve(address(router), _amount);
        }

        // swap ETH or source token for cfUSD
        (bool success, bytes memory result) = address(router).call{
            value: msg.value
        }(_data);
        if (!success) {
            revert(RevertReasonParser.parse(result, "callBytes failed: "));
        }

        // record amount of cfUSD received from swap
        uint amountOut = abi.decode(result, (uint));

        // if destination synth is NOT cfUSD, swap on SynDex is necessary
        if (_destSynthCurrencyKey != cfUSD_CURRENCY_KEY) {
            amountOut = swapOnSynDex(
                amountOut,
                cfUSD_CURRENCY_KEY,
                _destSynthCurrencyKey
            );
        }

        // send amount of destination synth to msg.sender
        address destSynthAddress = proxyForSynth(
            addressResolver.getSynth(_destSynthCurrencyKey)
        );
        IERC20(destSynthAddress).safeTransfer(msg.sender, amountOut);

        emit SwapInto(msg.sender, amountOut);
        return amountOut;
    }

    /// @inheritdoc ISynthSwap
    function uniswapSwapOutOf(
        bytes32 _sourceSynthCurrencyKey,
        address _destTokenAddress,
        uint _amountOfSynth,
        uint _expectedAmountOfCFUSDFromSwap,
        bytes calldata _data
    ) external override nonReentrant returns (uint) {
        // transfer synth to this contract
        address sourceSynthAddress = proxyForSynth(
            addressResolver.getSynth(_sourceSynthCurrencyKey)
        );
        IERC20(sourceSynthAddress).transferFrom(
            msg.sender,
            address(this),
            _amountOfSynth
        );

        // if source synth is NOT cfUSD, swap on SynDex is necessary
        if (_sourceSynthCurrencyKey != cfUSD_CURRENCY_KEY) {
            swapOnSynDex(
                _amountOfSynth,
                _sourceSynthCurrencyKey,
                cfUSD_CURRENCY_KEY
            );
        }

        // approve AggregationRouterV4 to spend cfUSD
        cfUSD.approve(address(router), _expectedAmountOfCFUSDFromSwap);

        // swap cfUSD for ETH or destination token
        (bool success, bytes memory result) = address(router).call(_data);
        if (!success) {
            revert(
                RevertReasonParser.parse(
                    result,
                    "SynthSwap: callBytes failed: "
                )
            );
        }

        // record amount of ETH or destination token received from swap
        uint amountOut = abi.decode(result, (uint));

        // send amount of ETH or destination token to msg.sender
        if (_destTokenAddress == ETH_ADDRESS) {
            (success, result) = msg.sender.call{value: amountOut}("");
            if (!success) {
                revert(
                    RevertReasonParser.parse(
                        result,
                        "SynthSwap: callBytes failed: "
                    )
                );
            }
        } else {
            IERC20(_destTokenAddress).safeTransfer(msg.sender, amountOut);
        }

        emit SwapOutOf(msg.sender, amountOut);

        // any remaining cfUSD in contract should be transferred to treasury
        uint remainingBalanceCFUSD = cfUSD.balanceOf(address(this));
        if (remainingBalanceCFUSD > 0) {
            cfUSD.safeTransfer(treasury, remainingBalanceCFUSD);
        }

        return amountOut;
    }

    /// @notice owner possesses ability to rescue tokens locked within contract
    function rescueFunds(IERC20 token, uint256 amount) external onlyOwner {
        token.safeTransfer(msg.sender, amount);
    }

    //////////////////////////////////////
    ///////// INTERNAL FUNCTIONS /////////
    //////////////////////////////////////

    /// @notice addressResolver fetches ISynDex address
    function syndex() internal view returns (ISynDex) {
        return
            ISynDex(
                addressResolver.requireAndGetAddress(
                    CONTRACT_SYNDEX,
                    "Could not get SynDex"
                )
            );
    }

    // /// @notice execute swap on 1inch
    // /// @dev token approval needed when source is not ETH
    // /// @dev either source or destination token will ALWAYS be cfUSD
    // /// @param _data specifying swap data
    // /// @param _areTokensInContract TODO
    // /// @return amount received from 1inch swap
    // function swapOn1inch(
    //     bytes calldata _data,
    //     bool _areTokensInContract
    // ) internal returns (uint, address) {
    //     // decode _data for 1inch swap
    //     (
    //         IAggregationExecutor executor,
    //         IAggregationRouterV4.SwapDescription memory desc,
    //         bytes memory routeData
    //     ) = abi.decode(
    //             _data,
    //             (
    //                 IAggregationExecutor,
    //                 IAggregationRouterV4.SwapDescription,
    //                 bytes
    //             )
    //         );

    //     // set swap description destination address to this contract
    //     desc.dstReceiver = payable(address(this));

    //     if (desc.srcToken != ETH_ADDRESS) {
    //         // if being called from swapInto, tokens have not been transfered to this contract
    //         if (!_areTokensInContract) {
    //             IERC20(desc.srcToken).safeTransferFrom(
    //                 msg.sender,
    //                 address(this),
    //                 desc.amount
    //             );
    //         }
    //         // approve AggregationRouterV4 to spend srcToken
    //         IERC20(desc.srcToken).approve(address(router), desc.amount);
    //     }

    //     // execute 1inch swap
    //     (uint amountOut, ) = router.swap{value: msg.value}(
    //         executor,
    //         desc,
    //         routeData
    //     );

    //     require(amountOut > 0, "SynthSwap: swapOn1inch failed");
    //     return (amountOut, desc.dstToken);
    // }

    /// @notice execute swap on SynDex
    /// @dev token approval is always required
    /// @param _amount of source synth to swap
    /// @param _sourceSynthCurrencyKey source synth key needed for executeExchange
    /// @param _destSynthCurrencyKey destination synth key needed for executeExchange
    /// @return amountOut: received from SynDex swap
    function swapOnSynDex(
        uint _amount,
        bytes32 _sourceSynthCurrencyKey,
        bytes32 _destSynthCurrencyKey
    ) internal returns (uint) {
        // execute SynDex swap
        uint amountOut = syndex().exchangeWithTracking(
            _sourceSynthCurrencyKey,
            _amount,
            _destSynthCurrencyKey,
            volumeRewards,
            TRACKING_CODE
        );

        require(amountOut > 0, "SynthSwap: swapOnSynDex failed");
        return amountOut;
    }

    /// @notice get the proxy address from the synth implementation contract
    /// @dev only possible because SynDex synths inherit Proxyable which track proxy()
    /// @param synthImplementation synth implementation address
    /// @return synthProxy proxy address
    function proxyForSynth(
        address synthImplementation
    ) internal returns (address synthProxy) {
        (bool success, bytes memory retVal) = synthImplementation.call(
            abi.encodeWithSignature("proxy()")
        );
        require(success, "get Proxy address failed");
        (synthProxy) = abi.decode(retVal, (address));
    }
}
