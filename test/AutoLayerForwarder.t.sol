// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../AutoLayerForwarder.sol";
import "../interfaces/IBalancer.sol";

contract AutoLayerForwarderTest is Test {
    AutoLayerForwarder forwarder;
    IBalancer balancerVault;
    address owner;

    function setUp() public {
        // Deploy mock balancer vault
        balancerVault = new IBalancerMock();

        // Set up the owner address
        owner = address(this);

        // Deploy the AutoLayerForwarder contract
        forwarder = new AutoLayerForwarder(
            address(0), // autoLayerPointsAddress
            address(0), // routerAddress
            address(0), // ETHUSDPriceFeedAdress
            address(balancerVault), // balancerVaultAddress
            address(0) // tokenProxyAddress
        );

        // Transfer ownership to the test contract
        forwarder.transferOwnership(owner);
    }

    function testGetBptAddress() public {
        // Create a fake poolId
        bytes32 poolId = keccak256("Pool");

        // Register the poolId with the mock balancer vault
        IBalancerMock(address(balancerVault)).registerPool(poolId);

        // Call getBptAddress with the poolId
        address bptAddress = forwarder.getBptAddress(poolId);

        // Assert that the returned address matches the expected mock address
        assertEq(bptAddress, address(balancerVault));
    }
}

// Mock implementation of the IBalancer interface
contract IBalancerMock is IBalancer {
    bytes32 private _poolId;
    address private _poolAddress;

    function registerPool(bytes32 poolId) external {
        _poolId = poolId;
        _poolAddress = address(this); // Use the mock contract's address as the pool address
    }

    function getPool(bytes32 poolId) external view returns (address, uint8) {
        require(poolId == _poolId, "Pool not found");
        return (_poolAddress, 0);
    }

    // Other functions are not implemented as they are not needed for the test
}
