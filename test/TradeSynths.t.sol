// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import {Setup} from "./Setup.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TradeSynthsTest is Setup {
    function setUp() public override {
        super.setUp();
    }

    function testTradeSynths() public {
        vm.startPrank(user4);
        IERC20(address(proxySFCX)).transfer(address(tradingRewards), 250 ether);
        IERC20(address(proxySFCX)).transfer(
            address(rewardsDistribution),
            250 ether
        );
        vm.stopPrank();

        vm.startPrank(user5);
        syndex.createMaxSynths();

        syndex.executeExchange("cfUSD", 100 ether, "cfETH");

        tradingRewards.closeCurrentPeriodWithRewards(
            tradingRewards.getPeriodRecordedFees(0)
        );

        assertEq(tradingRewards.getPeriodAvailableRewards(0), 0.2 ether);
        assertEq(tradingRewards.isPeriodClaimable(0), true);
        assertEq(tradingRewards.getPeriodRecordedFees(0), 0.2 ether);
        assertEq(tradingRewards.getAvailableRewards(), 0.2 ether);
        assertEq(
            tradingRewards.getAvailableRewardsForAccountForPeriod(user5, 0),
            0.2 ether
        );

        uint256 amountBefore = IERC20(address(proxySFCX)).balanceOf(user5);
        uint256 rewardAmount = tradingRewards
            .getAvailableRewardsForAccountForPeriod(user5, 0);

        tradingRewards.redeemRewardsForPeriod(0);

        assertEq(
            IERC20(address(proxySFCX)).balanceOf(user5),
            amountBefore + rewardAmount
        );

        vm.stopPrank();
    }
}
