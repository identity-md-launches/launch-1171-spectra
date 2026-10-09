// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @notice Drives the token with bounded inputs from a closed set of actors and keeps a ledger of what
///         every balance and allowance should be. Every handler either performs a call that must
///         succeed and records it, or performs a call that must fail and checks that it failed for the
///         right reason and changed nothing. With `fail-on-revert` on, any revert the handler did not
///         predict fails the run.
contract SpectraHandler is Test {
    SpectraToken public immutable token;
    address[] public actors;

    // Ledger of what the token should hold, per actor.
    mapping(address => uint256) public ghost_initial;
    mapping(address => uint256) public ghost_sent;
    mapping(address => uint256) public ghost_received;
    mapping(address => uint256) public ghost_burnedBy;
    mapping(address => mapping(address => uint256)) public ghost_allowance;
    uint256 public ghost_burned;

    // Call counters, so a run that never reached a path is visible.
    uint256 public calls_transfer;
    uint256 public calls_transferFrom;
    uint256 public calls_burn;
    uint256 public calls_burnFrom;
    uint256 public calls_unlimitedSpend;
    uint256 public calls_expectedReverts;

    constructor(SpectraToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i = 0; i < actors_.length; i++) {
            ghost_initial[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    // ----------------------------------------------------------------------------------------------
    // Happy paths: bounded so they must succeed.
    // ----------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");

        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        ghost_sent[from] += amount;
        ghost_received[to] += amount;
        calls_transfer++;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // One call in five grants the unlimited allowance, so the non-decrementing path is exercised.
        if (amount % 5 == 0) amount = type(uint256).max;

        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        assertEq(token.allowance(owner, spender), amount, "allowance not set to what was approved");
        ghost_allowance[owner][spender] = amount;
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed != type(uint256).max && allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (owner == to) {
            assertEq(token.balanceOf(owner), ownerBefore, "self-transferFrom changed balance");
        } else {
            assertEq(token.balanceOf(owner), ownerBefore - amount, "owner not debited exactly");
            assertEq(token.balanceOf(to), toBefore + amount, "recipient not credited exactly");
        }
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
            calls_unlimitedSpend++;
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented exactly");
            ghost_allowance[owner][spender] = allowed - amount;
        }
        ghost_sent[owner] += amount;
        ghost_received[to] += amount;
        calls_transferFrom++;
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));

        uint256 before = token.balanceOf(from);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        token.burn(amount);

        assertEq(token.balanceOf(from), before - amount, "burn did not debit exactly");
        assertEq(token.totalSupply(), supplyBefore - amount, "burn did not shrink supply exactly");
        ghost_burnedBy[from] += amount;
        ghost_burned += amount;
        calls_burn++;
    }

    function burnFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed != type(uint256).max && allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        uint256 before = token.balanceOf(owner);
        uint256 supplyBefore = token.totalSupply();
        vm.prank(spender);
        token.burnFrom(owner, amount);

        assertEq(token.balanceOf(owner), before - amount, "burnFrom did not debit exactly");
        assertEq(token.totalSupply(), supplyBefore - amount, "burnFrom did not shrink supply exactly");
        if (allowed == type(uint256).max) {
            assertEq(token.allowance(owner, spender), type(uint256).max, "unlimited allowance was decremented");
            calls_unlimitedSpend++;
        } else {
            assertEq(token.allowance(owner, spender), allowed - amount, "allowance not decremented exactly");
            ghost_allowance[owner][spender] = allowed - amount;
        }
        ghost_burnedBy[owner] += amount;
        ghost_burned += amount;
        calls_burnFrom++;
    }

    // ----------------------------------------------------------------------------------------------
    // Failure paths: the call must revert with the predicted error and change nothing.
    // ----------------------------------------------------------------------------------------------

    function transferOverBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);

        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, from, held, amount));
        token.transfer(to, amount);

        assertEq(token.balanceOf(from), held, "failed transfer debited sender");
        assertEq(token.balanceOf(to), toBefore, "failed transfer credited recipient");
        calls_expectedReverts++;
    }

    function transferFromOverLimit(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 limit = allowed == type(uint256).max ? held : (allowed < held ? allowed : held);
        uint256 amount = limit + bound(excess, 1, type(uint256).max - limit);

        // The allowance is checked before the balance, so an amount over both fails on the allowance.
        bytes memory expected;
        if (allowed != type(uint256).max && amount > allowed) {
            expected =
                abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, owner, spender, allowed, amount);
        } else {
            expected = abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, owner, held, amount);
        }

        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        vm.expectRevert(expected);
        token.transferFrom(owner, to, amount);

        assertEq(token.balanceOf(owner), held, "failed transferFrom debited owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom credited recipient");
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom consumed allowance");
        calls_expectedReverts++;
    }

    function burnOverBalance(uint256 fromSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, from, held, amount));
        token.burn(amount);

        assertEq(token.balanceOf(from), held, "failed burn debited holder");
        assertEq(token.totalSupply(), supplyBefore, "failed burn changed supply");
        calls_expectedReverts++;
    }

    function burnFromOverLimit(uint256 spenderSeed, uint256 ownerSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 held = token.balanceOf(owner);
        uint256 limit = allowed == type(uint256).max ? held : (allowed < held ? allowed : held);
        uint256 amount = limit + bound(excess, 1, type(uint256).max - limit);
        uint256 supplyBefore = token.totalSupply();

        bytes memory expected;
        if (allowed != type(uint256).max && amount > allowed) {
            expected =
                abi.encodeWithSelector(SpectraToken.InsufficientAllowance.selector, owner, spender, allowed, amount);
        } else {
            expected = abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, owner, held, amount);
        }

        vm.prank(spender);
        vm.expectRevert(expected);
        token.burnFrom(owner, amount);

        assertEq(token.balanceOf(owner), held, "failed burnFrom debited owner");
        assertEq(token.totalSupply(), supplyBefore, "failed burnFrom changed supply");
        assertEq(token.allowance(owner, spender), allowed, "failed burnFrom consumed allowance");
        calls_expectedReverts++;
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 held = token.balanceOf(from);
        vm.prank(from);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(from), held, "failed transfer to zero debited sender");
        calls_expectedReverts++;
    }

    function transferFromToZeroAddress(uint256 spenderSeed, uint256 ownerSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        uint256 allowed = token.allowance(owner, spender);
        // Stay within the allowance so the zero-address check is what fires.
        if (allowed != type(uint256).max) amount = bound(amount, 0, allowed);
        uint256 held = token.balanceOf(owner);

        vm.prank(spender);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.transferFrom(owner, address(0), amount);

        assertEq(token.balanceOf(owner), held, "failed transferFrom to zero debited owner");
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom to zero consumed allowance");
        calls_expectedReverts++;
    }

    function approveZeroAddress(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        vm.expectRevert(SpectraToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        calls_expectedReverts++;
    }
}

/// @notice Closed-world invariants: a fixed set of actors drives the token through the handler, and the
///         token's state must always agree with the handler's ledger.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SpectraTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SpectraToken token;
    SpectraHandler handler;
    address deployer = makeAddr("deployer");
    address[] actors;

    function setUp() public {
        vm.prank(deployer);
        token = new SpectraToken();

        actors.push(deployer);
        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));

        // Seed a spread of balances so flows start from more than one account: a large holder, a
        // tiny one and an empty one.
        vm.startPrank(deployer);
        token.transfer(actors[1], 100_000_000e18);
        token.transfer(actors[2], 1_000e18);
        token.transfer(actors[3], 1);
        vm.stopPrank();

        handler = new SpectraHandler(token, actors);
        targetContract(address(handler));
    }

    function _sumOfActorBalances() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
    }

    /// @dev Conservation: tokens live only in actor accounts, so their balances sum to the supply.
    function invariant_supplyEqualsSumOfBalances() public view {
        assertEq(_sumOfActorBalances(), token.totalSupply(), "balances do not sum to supply");
    }

    /// @dev The supply only ever shrinks, and only by what holders burned.
    function invariant_supplyNeverGrowsAndTracksBurns() public view {
        assertLe(token.totalSupply(), SUPPLY, "supply grew");
        assertEq(token.totalSupply(), SUPPLY - handler.ghost_burned(), "supply disagrees with burns");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY, "initial supply constant changed");
    }

    /// @dev Every balance equals what the actor started with plus what came in minus what went out.
    function invariant_eachBalanceMatchesLedger() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            uint256 expected = handler.ghost_initial(a) + handler.ghost_received(a) - handler.ghost_sent(a)
                - handler.ghost_burnedBy(a);
            assertEq(token.balanceOf(a), expected, "balance disagrees with ledger");
        }
    }

    /// @dev Every allowance equals what was approved minus what was spent, or stays unlimited.
    function invariant_allowancesMatchLedger() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            for (uint256 j = 0; j < actors.length; j++) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.ghost_allowance(actors[i], actors[j]),
                    "allowance disagrees with ledger"
                );
            }
        }
    }

    /// @dev Nothing can be routed to the zero address: burns shrink the supply instead of crediting it.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }

    function invariant_noBalanceExceedsSupply() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(token.balanceOf(actors[i]), token.totalSupply(), "a balance exceeds the supply");
        }
    }

    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Spectra");
        assertEq(token.symbol(), "SPECTRA");
        assertEq(token.decimals(), 18);
    }
}

/// @notice Open-world invariants: the fuzzer calls the token directly with arbitrary arguments from a
///         set of senders, so recipients can be any address and most calls revert. What must still hold
///         is that the supply never grows and nothing lands on the zero address.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract SpectraTokenOpenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SpectraToken token;
    address deployer = makeAddr("deployer");
    address[] senders;

    function setUp() public {
        vm.prank(deployer);
        token = new SpectraToken();

        senders.push(deployer);
        senders.push(makeAddr("alice"));
        senders.push(makeAddr("bob"));
        senders.push(makeAddr("stranger"));

        vm.startPrank(deployer);
        token.transfer(senders[1], 10_000_000e18);
        token.transfer(senders[2], 5e18);
        vm.stopPrank();

        targetContract(address(token));
        for (uint256 i = 0; i < senders.length; i++) {
            targetSender(senders[i]);
        }
    }

    function invariant_supplyNeverGrows() public view {
        assertLe(token.totalSupply(), SUPPLY, "supply grew");
    }

    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "zero address holds tokens");
    }

    /// @dev Known senders may have sent tokens anywhere, so their balances sum to at most the supply,
    ///      and no single balance can exceed it.
    function invariant_knownBalancesBoundedBySupply() public view {
        uint256 sum;
        for (uint256 i = 0; i < senders.length; i++) {
            uint256 held = token.balanceOf(senders[i]);
            assertLe(held, token.totalSupply(), "a balance exceeds the supply");
            sum += held;
        }
        assertLe(sum, token.totalSupply(), "known balances exceed the supply");
    }

    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Spectra");
        assertEq(token.symbol(), "SPECTRA");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }
}
