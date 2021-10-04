// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.6;

import "./test-helpers/Hevm.sol";
import { GClaim } from "../modules/GClaim.sol";
import "./test-helpers/TestHelper.sol";
import "solmate/erc20/ERC20.sol";

contract DividerMock {}

contract GClaims is TestHelper {
    /* ========== join() tests ========== */

    function testCantJoinIfInvalidMaturity() public {
        uint256 maturity = block.timestamp - 1 days;
        uint256 balance = 1e18;
        try alice.doJoin(address(feed), maturity, balance) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.InvalidMaturity);
        }
    }

    function testCantJoinIfClaimNotExists() public {
        uint256 maturity = getValidMaturity(2021, 10);
        uint256 balance = 10e18;
        try alice.doJoin(address(feed), maturity, balance) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.ClaimNotExists);
        }
    }

    function testCantJoinIfNotEnoughClaim() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        uint256 balance = 10e18;
        hevm.warp(block.timestamp + 1 days);
        bob.doApprove(address(claim), address(gclaim));
        try bob.doJoin(address(feed), maturity, balance) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.TransferFromFailed);
        }
    }

    function testCantJoinIfNotEnoughClaimAllowance() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        uint256 balance = 10e18;
        hevm.warp(block.timestamp + 1 days);
        bob.doIssue(address(feed), maturity, balance);
        uint256 claimBalance = Claim(claim).balanceOf(address(bob));
        try bob.doJoin(address(feed), maturity, claimBalance) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.TransferFromFailed);
        }
    }

    function testJoinFirstGClaim() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        uint256 balance = 10e18;
        hevm.warp(block.timestamp + 1 days);
        bob.doIssue(address(feed), maturity, balance);
        bob.doApprove(address(claim), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 claimBalance = Claim(claim).balanceOf(address(bob));
        bob.doJoin(address(feed), maturity, claimBalance);
        uint256 gclaimBalance = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        assertEq(gclaimBalance, claimBalance);
    }

    function testJoinAfterFirstGClaim() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        hevm.warp(block.timestamp + 1 days);

        // bob issues and joins
        uint256 balance = 10e18;
        bob.doIssue(address(feed), maturity, balance);
        bob.doApprove(address(claim), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 bobClaimBalance = Claim(claim).balanceOf(address(bob));
        bob.doJoin(address(feed), maturity, bobClaimBalance);
        uint256 bobGclaimBalance = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        assertEq(bobGclaimBalance, bobClaimBalance);

        // alice issues and joins
        hevm.warp(block.timestamp + 1 days);
        alice.doIssue(address(feed), maturity, balance);
        alice.doApprove(address(claim), address(gclaim));
        alice.doApprove(address(target), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 aliceClaimBalance = Claim(claim).balanceOf(address(alice));
        uint256 aliceTargetBalBefore = target.balanceOf(address(alice));
        alice.doJoin(address(feed), maturity, aliceClaimBalance);
        uint256 aliceTargetBalAfter = target.balanceOf(address(alice));
        uint256 aliceGclaimBalance = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(alice));
        assertEq(aliceGclaimBalance, aliceClaimBalance);
        assertTrue(aliceTargetBalAfter < aliceTargetBalBefore); // TODO: calculate exactly the value?
    }

    /* ========== exit() tests ========== */

    function testCantExitIfClaimNotExists() public {
        uint256 maturity = getValidMaturity(2021, 10);
        uint256 balance = 1e18;
        try alice.doExit(address(feed), maturity, balance) {
            fail();
        } catch Error(string memory error) {
            assertEq(error, Errors.ClaimNotExists);
        }
    }

    function testExitFirstGClaim() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        uint256 balance = 10e18;
        hevm.warp(block.timestamp + 1 days);
        bob.doIssue(address(feed), maturity, balance);
        bob.doApprove(address(claim), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 tBalanceBefore = target.balanceOf(address(bob));
        uint256 claimBalanceBefore = Claim(claim).balanceOf(address(bob));
        bob.doJoin(address(feed), maturity, claimBalanceBefore);
        uint256 gclaimBalanceBefore = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        bob.doExit(address(feed), maturity, gclaimBalanceBefore);
        uint256 gclaimBalanceAfter = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        uint256 claimBalanceAfter = Claim(claim).balanceOf(address(bob));
        uint256 tBalanceAfter = target.balanceOf(address(bob));
        assertEq(gclaimBalanceAfter, 0);
        assertEq(claimBalanceAfter, claimBalanceBefore);
        assertEq(tBalanceBefore, tBalanceAfter);
    }

    function testExitGClaimWithCollected() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        uint256 balance = 10e18;
        hevm.warp(block.timestamp + 1 days);
        bob.doIssue(address(feed), maturity, balance);
        bob.doApprove(address(claim), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 tBalanceBefore = target.balanceOf(address(bob));
        uint256 claimBalanceBefore = Claim(claim).balanceOf(address(bob));
        bob.doJoin(address(feed), maturity, claimBalanceBefore);
        hevm.warp(block.timestamp + 3 days);
        uint256 gclaimBalanceBefore = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        bob.doExit(address(feed), maturity, gclaimBalanceBefore);
        uint256 gclaimBalanceAfter = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        uint256 claimBalanceAfter = Claim(claim).balanceOf(address(bob));
        uint256 tBalanceAfter = target.balanceOf(address(bob));
        assertEq(gclaimBalanceAfter, 0);
        assertEq(claimBalanceAfter, claimBalanceBefore);
        assertTrue(tBalanceAfter > tBalanceBefore); // TODO: assert exact collected value
    }

    function testExitAfterFirstGClaim() public {
        uint256 maturity = getValidMaturity(2021, 10);
        (, address claim) = initSampleSeries(address(alice), maturity);
        hevm.warp(block.timestamp + 1 days);

        // bob issues and joins
        uint256 balance = 10e18;
        bob.doIssue(address(feed), maturity, balance);
        bob.doApprove(address(claim), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 bobClaimBalance = Claim(claim).balanceOf(address(bob));
        bob.doJoin(address(feed), maturity, bobClaimBalance);
        uint256 bobGclaimBalance = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(bob));
        assertEq(bobGclaimBalance, bobClaimBalance);

        // alice issues and joins
        hevm.warp(block.timestamp + 1 days);
        alice.doIssue(address(feed), maturity, balance);
        alice.doApprove(address(claim), address(gclaim));
        alice.doApprove(address(target), address(gclaim));
        hevm.warp(block.timestamp + 1 days);
        uint256 aliceClaimBalance = Claim(claim).balanceOf(address(alice));
        alice.doJoin(address(feed), maturity, aliceClaimBalance);
        uint256 aliceGclaimBalance = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(alice));
        assertEq(aliceGclaimBalance, aliceClaimBalance);

        // alice exits
        hevm.warp(block.timestamp + 3 days);
        uint256 tBalanceBefore = target.balanceOf(address(alice));
        alice.doExit(address(feed), maturity, aliceGclaimBalance);
        uint256 gclaimBalanceAfter = ERC20(gclaim.gclaims(address(claim))).balanceOf(address(alice));
        uint256 claimBalanceAfter = Claim(claim).balanceOf(address(alice));
        uint256 tBalanceAfter = target.balanceOf(address(alice));
        assertEq(gclaimBalanceAfter, 0);
        assertEq(claimBalanceAfter, aliceGclaimBalance);
        assertTrue(tBalanceAfter > tBalanceBefore);
    }
}
