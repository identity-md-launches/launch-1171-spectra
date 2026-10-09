// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpectraToken} from "../src/SpectraToken.sol";
import {DeploySpectra} from "../script/DeploySpectra.s.sol";

/// @notice A contract that deploys the token, to show the supply goes to whoever runs the constructor
///         (the launch factory in production) and not to any fixed address.
contract Deployer {
    SpectraToken public token;

    function deploy() external {
        token = new SpectraToken();
    }
}

contract SpectraTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address spender = makeAddr("spender");

    SpectraToken token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new SpectraToken();
    }

    // ----------------------------------------------------------------------------------------------
    // Metadata and supply
    // ----------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Spectra");
        assertEq(token.symbol(), "SPECTRA");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), deployer, SUPPLY);
        vm.prank(deployer);
        new SpectraToken();
    }

    function test_supplyGoesToTheContractThatDeploys() public {
        Deployer factory = new Deployer();
        factory.deploy();
        SpectraToken deployed = factory.token();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_deployScriptFunctionMintsToCaller() public {
        DeploySpectra script = new DeploySpectra();
        SpectraToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------------
    // transfer
    // ----------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1_000e18);
        assertTrue(token.transfer(alice, 1_000e18));
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(bob, 10e18 + 1);
    }

    function test_RevertWhen_transferFromEmptyAccount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    // ----------------------------------------------------------------------------------------------
    // approve / allowance / transferFrom
    // ----------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 7e18);
        assertTrue(token.approve(spender, 7e18));
        assertEq(token.allowance(deployer, spender), 7e18);
    }

    function test_approveOverwritesPriorAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 7e18);
        token.approve(spender, 2e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 2e18);
    }

    function test_RevertWhen_approveZeroAddressSpender() public {
        vm.prank(deployer);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);

        vm.prank(spender);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 4e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 6e18);
        assertTrue(token.transferFrom(deployer, bob, 6e18));

        assertEq(token.balanceOf(bob), 6e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 6e18);
        assertEq(token.allowance(deployer, spender), 4e18);
        assertEq(token.balanceOf(spender), 0);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 6e18);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 6e18);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, 5e18, 5e18 + 1)
        );
        token.transferFrom(deployer, bob, 5e18 + 1);
    }

    function test_RevertWhen_transferFromWithoutAllowance() public {
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_RevertWhen_transferFromExceedsBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(spender, 100e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 0, 1e18));
        token.transferFrom(alice, bob, 1e18);
    }

    function test_RevertWhen_transferFromToZeroAddress() public {
        vm.prank(deployer);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transferFrom(deployer, address(0), 1);
    }

    /// @dev The deployer has no special hand: without an allowance it cannot pull a holder's tokens.
    function test_RevertWhen_deployerPullsFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, alice, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10e18);
    }

    // ----------------------------------------------------------------------------------------------
    // burn / burnFrom
    // ----------------------------------------------------------------------------------------------

    function test_burnReducesBalanceAndSupply() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 4e18);
        token.burn(4e18);
        assertEq(token.balanceOf(alice), 6e18);
        assertEq(token.totalSupply(), SUPPLY - 4e18);
    }

    function test_RevertWhen_burnExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 0, 1));
        token.burn(1);
    }

    function test_burnFromSpendsAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(spender, 3e18);
        vm.prank(spender);
        token.burnFrom(alice, 3e18);
        assertEq(token.balanceOf(alice), 7e18);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY - 3e18);
    }

    function test_RevertWhen_burnFromWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, alice, deployer, 0, 1e18));
        token.burnFrom(alice, 1e18);
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------------
    // No privileged surface: no mint, no pause, no blacklist, no owner.
    // ----------------------------------------------------------------------------------------------

    function test_noAdminCallExistsOrGrowsSupply() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    // ----------------------------------------------------------------------------------------------
    // Fuzz: transfers conserve supply and move exactly what is asked.
    // ----------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            assertTrue(token.transferFrom(deployer, bob, amount));
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, spender), allowed - amount);
        }
    }

    function testFuzz_transferOverBalanceReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, held, amount));
        token.transfer(bob, amount);
    }
}
