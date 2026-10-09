// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @notice The ERC-20 surface as a caller that knows only the standard would see it. Declared here so
///         the selectors the launch factory and the pool manager use are checked against the token's
///         ABI, not against the token's own type.
interface IERC20Standard {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Edge cases and failure paths beyond the base suite: boundaries of burn and burnFrom, the
///         allowance just under unlimited, zero amounts without allowances, calls from the zero
///         address, repeated calls, unknown selectors, and property tests over the arithmetic.
/// forge-config: default.fuzz.runs = 1000
contract SpectraTokenEdgesTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant MAX = type(uint256).max;

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
    // Metadata and ABI conformance
    // ----------------------------------------------------------------------------------------------

    function test_standardSelectorsAnswer() public {
        IERC20Standard std = IERC20Standard(address(token));
        assertEq(std.name(), "Spectra");
        assertEq(std.symbol(), "SPECTRA");
        assertEq(std.decimals(), 18);
        assertEq(std.totalSupply(), SUPPLY);
        assertEq(std.balanceOf(deployer), SUPPLY);
        assertEq(std.allowance(deployer, spender), 0);

        vm.prank(deployer);
        assertTrue(std.transfer(alice, 1e18));
        vm.prank(alice);
        assertTrue(std.approve(spender, 1e18));
        vm.prank(spender);
        assertTrue(std.transferFrom(alice, bob, 1e18));
        assertEq(std.balanceOf(bob), 1e18);
    }

    /// @dev The raw four-byte selectors every ERC-20 integrator hard-codes, sent as bare calldata.
    function test_standardSelectorsByRawBytes() public {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeWithSelector(0x18160ddd));
        assertTrue(ok, "totalSupply()");
        assertEq(abi.decode(ret, (uint256)), SUPPLY);
        (ok, ret) = address(token).staticcall(abi.encodeWithSelector(0x70a08231, deployer));
        assertTrue(ok, "balanceOf(address)");
        assertEq(abi.decode(ret, (uint256)), SUPPLY);
        (ok, ret) = address(token).staticcall(abi.encodeWithSelector(0xdd62ed3e, deployer, spender));
        assertTrue(ok, "allowance(address,address)");
        assertEq(abi.decode(ret, (uint256)), 0);
        (ok, ret) = address(token).staticcall(abi.encodeWithSelector(0x313ce567));
        assertTrue(ok, "decimals()");
        assertEq(abi.decode(ret, (uint8)), 18);
        (ok, ret) = address(token).staticcall(abi.encodeWithSelector(0x06fdde03));
        assertTrue(ok, "name()");
        assertEq(abi.decode(ret, (string)), "Spectra");
        (ok, ret) = address(token).staticcall(abi.encodeWithSelector(0x95d89b41));
        assertTrue(ok, "symbol()");
        assertEq(abi.decode(ret, (string)), "SPECTRA");

        vm.prank(deployer);
        (ok, ret) = address(token).call(abi.encodeWithSelector(0xa9059cbb, alice, 2e18));
        assertTrue(ok, "transfer(address,uint256)");
        assertTrue(abi.decode(ret, (bool)));
        vm.prank(alice);
        (ok, ret) = address(token).call(abi.encodeWithSelector(0x095ea7b3, spender, 2e18));
        assertTrue(ok, "approve(address,uint256)");
        assertTrue(abi.decode(ret, (bool)));
        vm.prank(spender);
        (ok, ret) = address(token).call(abi.encodeWithSelector(0x23b872dd, alice, bob, 2e18));
        assertTrue(ok, "transferFrom(address,address,uint256)");
        assertTrue(abi.decode(ret, (bool)));
        assertEq(token.balanceOf(bob), 2e18);
    }

    function test_metadataExactBytes() public view {
        assertEq(bytes(token.name()).length, 7);
        assertEq(bytes(token.symbol()).length, 7);
        assertEq(keccak256(bytes(token.name())), keccak256("Spectra"));
        assertEq(keccak256(bytes(token.symbol())), keccak256("SPECTRA"));
    }

    function test_supplyInWholeTokens() public view {
        assertEq(token.totalSupply() / 10 ** token.decimals(), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** token.decimals(), 0);
    }

    function test_runtimeFitsEip170() public view {
        assertLe(address(token).code.length, 24_576);
    }

    function test_RevertWhen_unknownSelectorIsCalled() public {
        (bool ok,) = address(token)
            .call(abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));
        assertFalse(ok, "unknown selector accepted");
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "random selector accepted");
        (ok,) = address(token).call("");
        assertFalse(ok, "empty calldata accepted");
    }

    function test_RevertWhen_etherSentWithKnownSelector() public {
        vm.deal(deployer, 1 ether);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(SpectraToken.transfer, (alice, 1)));
        assertFalse(ok, "non-payable function accepted ether");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(alice);
        SpectraToken other = new SpectraToken();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        vm.prank(alice);
        other.burn(SUPPLY);
        assertEq(other.totalSupply(), 0);
        assertEq(token.totalSupply(), SUPPLY, "burning one deployment touched another");
    }

    // ----------------------------------------------------------------------------------------------
    // transfer edges
    // ----------------------------------------------------------------------------------------------

    function test_zeroValueTransferEmitsEvent() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0);
        token.transfer(bob, 0);
    }

    function test_transferOneWeiRepeatedUntilEmpty() public {
        vm.prank(deployer);
        token.transfer(alice, 3);
        vm.startPrank(alice);
        token.transfer(bob, 1);
        token.transfer(bob, 1);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 3);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.stopPrank();
    }

    function test_sameTransferTwiceFailsTheSecondTime() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.startPrank(alice);
        assertTrue(token.transfer(bob, 10e18));
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 0, 10e18));
        token.transfer(bob, 10e18);
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_RevertWhen_transferMaxUint() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, SUPPLY, MAX));
        token.transfer(alice, MAX);
    }

    function test_RevertWhen_transferSupplyPlusOne() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        token.transfer(alice, SUPPLY + 1);
    }

    function test_RevertWhen_selfTransferExceedsBalance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        token.transfer(deployer, SUPPLY + 1);
    }

    function test_RevertWhen_transferZeroAmountToZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transfer(address(0), 0);
    }

    function test_transferToTokenContractIsAllowedButStranded() public {
        // Nothing forbids it, and nothing can ever move it out: the contract has no sweep.
        vm.prank(deployer);
        token.transfer(address(token), 5e18);
        assertEq(token.balanceOf(address(token)), 5e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The zero address can never be a source of tokens, even if it could call approve.
    function test_RevertWhen_transferFromZeroAddressSource() public {
        vm.prank(address(0));
        token.approve(spender, MAX);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, address(0), 0, 1));
        token.transferFrom(address(0), bob, 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ----------------------------------------------------------------------------------------------
    // approve / transferFrom edges
    // ----------------------------------------------------------------------------------------------

    function test_approveZeroClearsAllowanceAndEmits() public {
        vm.startPrank(deployer);
        token.approve(spender, 5e18);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_approveSelfIsAllowed() public {
        vm.startPrank(deployer);
        token.approve(deployer, 3e18);
        assertEq(token.allowance(deployer, deployer), 3e18);
        token.transferFrom(deployer, alice, 3e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 3e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev ERC-20 grants no implicit self-allowance: the owner cannot pull from itself without approving.
    function test_RevertWhen_ownerTransferFromSelfWithoutAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_approveCanExceedBalance() public {
        vm.prank(alice);
        token.approve(spender, MAX - 1);
        assertEq(token.allowance(alice, spender), MAX - 1);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(spender);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 0);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 0);
        assertTrue(token.transferFrom(deployer, bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(spender, 7);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, 7);
        assertEq(token.allowance(deployer, spender), 0);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
    }

    /// @dev Only exactly type(uint256).max is unlimited; one less is an ordinary allowance.
    function test_allowanceMaxMinusOneIsDecremented() public {
        vm.prank(deployer);
        token.approve(spender, MAX - 1);
        vm.prank(spender);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, MAX - 1 - 4e18);
        token.transferFrom(deployer, bob, 4e18);
        assertEq(token.allowance(deployer, spender), MAX - 1 - 4e18);
    }

    function test_unlimitedAllowanceEmitsNoApprovalOnSpend() public {
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.prank(spender);
        vm.recordLogs();
        token.transferFrom(deployer, bob, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "expected only the Transfer event");
        assertEq(logs[0].topics[0], Transfer.selector);
        assertEq(token.allowance(deployer, spender), MAX);
    }

    function test_unlimitedAllowanceSurvivesDrainingTheOwner() public {
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, spender), MAX);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, 0, 1));
        token.transferFrom(deployer, bob, 1);
        vm.stopPrank();
    }

    function test_RevertWhen_transferFromOverBalanceConsumesNoAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(spender, 20e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transferFrom(alice, bob, 10e18 + 1);
        assertEq(token.allowance(alice, spender), 20e18, "a reverted transferFrom consumed allowance");
        assertEq(token.balanceOf(alice), 10e18);
    }

    function test_RevertWhen_transferFromToZeroWithUnlimitedAllowance() public {
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.prank(spender);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_allowanceIsPerSpender() public {
        vm.startPrank(deployer);
        token.approve(spender, 5e18);
        token.approve(alice, 1e18);
        vm.stopPrank();
        vm.prank(spender);
        token.transferFrom(deployer, bob, 5e18);
        assertEq(token.allowance(deployer, alice), 1e18, "spending one allowance touched another");
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_allowanceIsDirectional() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        assertEq(token.allowance(bob, alice), 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, bob, alice, 0, 1));
        token.transferFrom(bob, alice, 1);
    }

    // ----------------------------------------------------------------------------------------------
    // burn / burnFrom edges
    // ----------------------------------------------------------------------------------------------

    function test_burnZeroEmitsAndChangesNothing() public {
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(0), 0);
        token.burn(0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnWholeSupplyLeavesZero() public {
        vm.prank(deployer);
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(address(0)), 0, "burn credited the zero address");
        // Zero-value calls still work on an empty token, and nothing else does.
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 0));
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, 0, 1));
        token.burn(1);
    }

    function test_RevertWhen_burnOneOverBalance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.burn(10e18 + 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_burnMaxUint() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, deployer, SUPPLY, MAX));
        token.burn(MAX);
    }

    function test_burnFromWithUnlimitedAllowanceDoesNotDecrement() public {
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.prank(spender);
        token.burnFrom(deployer, 2e18);
        assertEq(token.allowance(deployer, spender), MAX);
        assertEq(token.totalSupply(), SUPPLY - 2e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 2e18);
    }

    function test_burnFromZeroWithoutAllowanceSucceeds() public {
        vm.prank(spender);
        token.burnFrom(deployer, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_burnFromEmitsApprovalAndTransfer() public {
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, spender, 2e18);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, address(0), 3e18);
        token.burnFrom(deployer, 3e18);
    }

    function test_RevertWhen_burnFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 5e18);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, spender, 5e18, 5e18 + 1)
        );
        token.burnFrom(deployer, 5e18 + 1);
        assertEq(token.allowance(deployer, spender), 5e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_burnFromExceedsBalanceConsumesNoAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(spender, 20e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, 10e18, 11e18));
        token.burnFrom(alice, 11e18);
        assertEq(token.allowance(alice, spender), 20e18, "a reverted burnFrom consumed allowance");
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The exact call the launch floor makes: burnFrom(holder, true) from the deployer, which
    ///      decodes to amount 1. It must revert and leave the holder whole.
    function test_RevertWhen_deployerBurnsFromHolderWithBoolEncodedAmount() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(deployer);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, true));
        assertFalse(ok, "deployer burned from a holder without allowance");
        assertEq(token.balanceOf(alice), 10e18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_RevertWhen_burnFromSelfWithoutAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, deployer, deployer, 0, 1));
        token.burnFrom(deployer, 1);
    }

    // ----------------------------------------------------------------------------------------------
    // Property tests over the arithmetic
    // ----------------------------------------------------------------------------------------------

    function testFuzz_transferOracle(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.prank(alice);
        if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, held, amount));
            token.transfer(bob, amount);
            assertEq(token.balanceOf(alice), held);
            assertEq(token.balanceOf(bob), 0);
        } else {
            assertTrue(token.transfer(bob, amount));
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.balanceOf(bob), amount);
        }
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_selfTransferIsIdentity(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    function testFuzz_approveRoundTrip(address owner, address spender_, uint256 amount) public {
        if (spender_ == address(0)) spender_ = address(1);
        vm.prank(owner);
        assertTrue(token.approve(spender_, amount));
        assertEq(token.allowance(owner, spender_), amount);
        // Approve is idempotent: the same call again leaves the same value.
        vm.prank(owner);
        token.approve(spender_, amount);
        assertEq(token.allowance(owner, spender_), amount);
    }

    function testFuzz_burnOracle(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.prank(alice);
        if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, held, amount));
            token.burn(amount);
            assertEq(token.totalSupply(), SUPPLY);
        } else {
            token.burn(amount);
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.totalSupply(), SUPPLY - amount);
        }
        assertEq(token.balanceOf(alice) + token.balanceOf(deployer), token.totalSupply());
    }

    function testFuzz_burnFromOracle(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, allowed);

        vm.prank(spender);
        if (allowed != MAX && amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, alice, spender, allowed, amount)
            );
            token.burnFrom(alice, amount);
            assertEq(token.allowance(alice, spender), allowed);
            assertEq(token.totalSupply(), SUPPLY);
        } else if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, alice, held, amount));
            token.burnFrom(alice, amount);
            assertEq(token.allowance(alice, spender), allowed);
            assertEq(token.totalSupply(), SUPPLY);
        } else {
            token.burnFrom(alice, amount);
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.totalSupply(), SUPPLY - amount);
            assertEq(token.allowance(alice, spender), allowed == MAX ? MAX : allowed - amount);
        }
    }

    function testFuzz_unlimitedAllowanceNeverChanges(uint256 amount, uint256 burnAmount) public {
        amount = bound(amount, 0, SUPPLY);
        burnAmount = bound(burnAmount, 0, SUPPLY - amount);
        vm.prank(deployer);
        token.approve(spender, MAX);
        vm.startPrank(spender);
        token.transferFrom(deployer, bob, amount);
        token.burnFrom(deployer, burnAmount);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), MAX);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.totalSupply(), SUPPLY - burnAmount);
    }

    function testFuzz_splitTransfersSumExactly(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        vm.startPrank(deployer);
        token.transfer(alice, first);
        token.transfer(alice, total - first);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
    }

    function testFuzz_burnsAccumulateExactly(uint256 a, uint256 b) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        vm.startPrank(deployer);
        token.burn(a);
        token.burn(b);
        vm.stopPrank();
        assertEq(token.totalSupply(), SUPPLY - a - b);
        assertEq(token.balanceOf(deployer), SUPPLY - a - b);
    }

    function testFuzz_noCallerCanGrowSupply(address caller, bytes4 selector, uint256 a, uint256 b) public {
        bytes memory data = abi.encodeWithSelector(selector, caller, a, b);
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertLe(token.totalSupply(), SUPPLY, "supply grew");
        assertEq(token.balanceOf(address(0)), 0, "zero address was credited");
    }

    function testFuzz_strangerCannotMoveHolderBalance(address stranger, uint256 held, uint256 amount) public {
        vm.assume(stranger != alice && stranger != deployer);
        held = bound(held, 1, SUPPLY);
        amount = bound(amount, 1, MAX);
        vm.prank(deployer);
        token.transfer(alice, held);

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, alice, stranger, 0, amount));
        token.transferFrom(alice, stranger, amount);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, alice, stranger, 0, amount));
        token.burnFrom(alice, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), held);
    }
}
