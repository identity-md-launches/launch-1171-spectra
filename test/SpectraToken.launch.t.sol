// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpectraToken} from "../src/SpectraToken.sol";

/// @notice Stands in for the launch factory: deploys the token's creation code through raw CREATE2 the
///         way the factory does, so the supply lands on the factory, then pays the launch out.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(SpectraToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function pull(SpectraToken token, address from, address to, uint256 amount) external returns (bool) {
        return token.transferFrom(from, to, amount);
    }
}

/// @notice The launch flows as the factory performs them, with the manifest's numbers: ten percent to
///         the distributor, the pool share to the pool manager, the rest to the requester, and every
///         flow arriving whole. The token must not treat the factory, the manager or the distributor
///         any differently from a trader, and the numbers must add up to the supply exactly.
contract SpectraTokenLaunchTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 constant SWARM_BPS = 1_000;
    uint256 constant POOL_BPS = 8_800;

    FactoryProbe factory;
    SpectraToken token;

    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant POOL_MANAGER = address(0x900C);
    address constant TRADER = address(0x7A4D);
    address constant REMAINDER_TO = 0x6bF192eBEf135E0F645e99d59d9BF44E7711606c;

    function setUp() public {
        factory = new FactoryProbe();
        token = SpectraToken(factory.deploy(type(SpectraToken).creationCode, bytes32(uint256(42))));
    }

    function test_creationCodeTakesNoArguments() public {
        // The manifest lists constructorArgs []: appending any argument must not change what deploys.
        bytes memory code = type(SpectraToken).creationCode;
        address predicted = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(uint256(7)), keccak256(code)))
                )
            )
        );
        address deployed = factory.deploy(code, bytes32(uint256(7)));
        assertEq(deployed, predicted, "CREATE2 address did not match the prediction");
        assertEq(SpectraToken(deployed).balanceOf(address(factory)), SUPPLY);
    }

    function test_supplyMintedToTheFactory() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(tx.origin), 0);
    }

    function test_swarmShareArrivesWholeAndIsClaimableWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertEq(swarm, 100_000_000e18);
        assertTrue(factory.move(token, DISTRIBUTOR, swarm));
        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm);
        assertEq(token.balanceOf(DISTRIBUTOR), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullPayoutSumsToSupplyExactly() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        assertEq(remainder, 20_000_000e18);

        factory.move(token, DISTRIBUTOR, swarm);
        factory.move(token, POOL_MANAGER, pool);
        factory.move(token, REMAINDER_TO, remainder);

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(address(factory)), 0, "the factory kept something back");
        assertEq(swarm + pool + remainder, token.totalSupply());

        // Nothing is left to pay: the factory's next transfer fails and moves nothing.
        vm.expectRevert(abi.encodeWithSelector(SpectraToken.InsufficientBalance.selector, address(factory), 0, 1));
        factory.move(token, REMAINDER_TO, 1);
    }

    /// @dev The pool manager pulls the seed with transferFrom against an approval and pays traders with
    ///      transfer. Both must move exactly what they say, in both directions.
    function test_poolManagerPullsSeedAndPaysTradersExactly() public {
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        FactoryProbe manager = new FactoryProbe();
        // The factory approves the manager, which pulls the seed.
        vm.prank(address(factory));
        token.approve(address(manager), pool);
        assertTrue(manager.pull(token, address(factory), address(manager), pool));
        assertEq(token.balanceOf(address(manager)), pool);
        assertEq(token.allowance(address(factory), address(manager)), 0);

        // Buy: the manager pays a trader.
        assertTrue(manager.move(token, TRADER, 1_234e18));
        assertEq(token.balanceOf(TRADER), 1_234e18);
        // Sell: the trader pays the manager back.
        vm.prank(TRADER);
        assertTrue(token.transfer(address(manager), 1_234e18));
        assertEq(token.balanceOf(TRADER), 0);
        assertEq(token.balanceOf(address(manager)), pool);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev The factory has no hand on a holder after paying out: the same privileged calls the launch
    ///      floor tries, from the factory, all fail and the holder keeps everything.
    function test_factoryCannotMoveOrFreezeAHolderAfterwards() public {
        factory.move(token, TRADER, SUPPLY / 1_000);
        uint256 held = token.balanceOf(TRADER);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "mint(address,uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], TRADER, true));
            assertFalse(ok, signatures[i]);
        }
        vm.prank(address(factory));
        (bool moved,) = address(token).call(abi.encodeCall(SpectraToken.transferFrom, (TRADER, address(factory), 1)));
        assertFalse(moved, "the factory pulled from a holder");
        assertEq(token.balanceOf(TRADER), held);
        assertEq(token.totalSupply(), SUPPLY);

        vm.prank(TRADER);
        assertTrue(token.transfer(CLAIMANT, held / 2));
        assertEq(token.balanceOf(CLAIMANT), held / 2);
    }

    /// @dev Whatever bps split the manifest names, the three flows leave the factory whole and empty.
    function testFuzz_anySplitArrivesWhole(uint256 poolBps) public {
        poolBps = bound(poolBps, 0, 10_000 - SWARM_BPS);
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * poolBps) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        factory.move(token, DISTRIBUTOR, swarm);
        factory.move(token, POOL_MANAGER, pool);
        factory.move(token, REMAINDER_TO, remainder);

        assertEq(token.balanceOf(DISTRIBUTOR), swarm);
        assertEq(token.balanceOf(POOL_MANAGER), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(
            token.balanceOf(DISTRIBUTOR) + token.balanceOf(POOL_MANAGER) + token.balanceOf(REMAINDER_TO),
            token.totalSupply()
        );
    }
}
