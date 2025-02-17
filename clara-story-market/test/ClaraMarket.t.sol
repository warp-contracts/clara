// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ClaraMarketV1} from "../src/ClaraMarketV1.sol";
import {MarketLib} from "../src/MarketLib.sol";
import {RevenueToken} from "../src/mocks/RevenueToken.sol";
import {AgentNFT} from "../src/mocks/AgentNFT.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdChains} from "forge-std/StdChains.sol";
import {StdCheats, StdCheatsSafe} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import { MockIPGraph } from "@storyprotocol/test/mocks/MockIPGraph.sol";
import { IPAssetRegistry } from "@storyprotocol/core/registries/IPAssetRegistry.sol";
import { LicenseRegistry } from "@storyprotocol/core/registries/LicenseRegistry.sol";

// TODO: Update to IP Asset version
contract ClaraMarketTest is Test {
    RevenueToken internal revToken;
    ClaraMarketV1 internal market;
    AgentNFT internal agentNft;

    // Two test addresses
    address internal agent_1 = address(0x1111);
    address internal agent_2 = address(0x2222);
    address internal agent_3 = address(0x3333);

    // "IPAssetRegistry": "0x77319B4031e6eF1250907aa00018B8B1c67a244b",
    address internal ipAssetRegistry = 0x77319B4031e6eF1250907aa00018B8B1c67a244b;
    // "LicensingModule": "0x04fbd8a2e56dd85CFD5500A4A4DfA955B9f1dE6f",
    address internal licensingModule = 0x04fbd8a2e56dd85CFD5500A4A4DfA955B9f1dE6f;
    // "PILicenseTemplate": "0x2E896b0b2Fdb7457499B56AAaA4AE55BCB4Cd316",
    address internal pilTemplate = 0x2E896b0b2Fdb7457499B56AAaA4AE55BCB4Cd316;
    // "RoyaltyPolicyLAP": "0xBe54FB168b3c982b7AaE60dB6CF75Bd8447b390E",
    address internal royaltyPolicyLAP = 0xBe54FB168b3c982b7AaE60dB6CF75Bd8447b390E;
    // "RoyaltyWorkflows": "0x9515faE61E0c0447C6AC6dEe5628A2097aFE1890",
    address internal royaltyWorkflows = 0x9515faE61E0c0447C6AC6dEe5628A2097aFE1890;
    //  "RoyaltyModule": "0xD2f60c40fEbccf6311f8B47c4f2Ec6b040400086",
    address internal royaltyModule = 0xD2f60c40fEbccf6311f8B47c4f2Ec6b040400086;
    // "WIP": "0x1514000000000000000000000000000000000000"
    address payable internal _revenueToken = payable(0x1514000000000000000000000000000000000000);

    // Protocol Core - LicenseRegistry
    address internal licenseRegistry = 0x529a750E02d8E2f15649c13D69a465286a780e24;
   
    function setUp() public {
        // this is only for testing purposes
        // due to our IPGraph precompile not being
        // deployed on the fork
        vm.etch(address(0x0101), address(new MockIPGraph()).code);
        
        revToken = RevenueToken(_revenueToken);

        // 2. Mint some tokens to our test users
        vm.startPrank(agent_1);
        vm.deal(agent_1, 10000 ether);
        revToken.deposit{value: 1000 ether}();
        vm.stopPrank();
        
        vm.startPrank(agent_2);
        vm.deal(agent_2, 10000 ether);
        revToken.deposit{value: 1000 ether}();
        vm.stopPrank();
        
        vm.startPrank(agent_3);
        vm.deal(agent_3, 10000 ether);
        revToken.deposit{value: 1000 ether}();
        vm.stopPrank();

        // 3. Deploy the ClaraMarket contract
        market = new ClaraMarketV1(
            ipAssetRegistry,
            licensingModule,
            pilTemplate,
            royaltyPolicyLAP,
            royaltyWorkflows,
            royaltyModule,
            _revenueToken);

        agentNft = AgentNFT(market.AGENT_NFT());
    }

    function testRegisterAgentProfile() public {
        vm.startPrank(agent_1);
        IPAssetRegistry IP_ASSET_REGISTRY = IPAssetRegistry(ipAssetRegistry);
        LicenseRegistry LICENSE_REGISTRY = LicenseRegistry(licenseRegistry);

        uint256 expectedTokenId = agentNft.nextTokenId();
        address expectedIpId = IP_ASSET_REGISTRY.ipId(block.chainid, address(agentNft), expectedTokenId);

        market.registerAgentProfile(50, "chat", "some metadata");
        (address licenseTemplate, uint256 attachedLicenseTermsId) = LICENSE_REGISTRY.getAttachedLicenseTerms({
            ipId: expectedIpId,
            index: 0
        });
        
        vm.stopPrank();
        (   bool exists,            // ensures we know if the agent is registered
            address id, // agent's wallet
            address ipAssetId,
            uint256 storedFee,            // how much an agent charges for the assigned tasks
            uint256 canNftTokenId,
            uint256 licenceTermsId,
            bytes32 storedTopic,           // e.g. "tweet", "discord", ...
            string memory storedMetadata
        ) = market.agents(agent_1);

        assertTrue(exists, "Agent should exist after registration");
        assertEq(id, agent_1, "Agent address mismatch");
        assertEq(storedTopic, "chat", "Agent topic mismatch");
        assertEq(storedFee, 50, "Agent fee mismatch");
        assertEq(storedMetadata, "some metadata", "Agent metadata mismatch");
        assertEq(ipAssetId, expectedIpId, "IP Asset ID mismatch");
        assertEq(canNftTokenId, expectedTokenId, "Token ID mismatch");
        assertEq(licenceTermsId, attachedLicenseTermsId, "License terms ID mismatch");
    }

    function testCheapestStrategy() public {
        vm.startPrank(agent_1);
        market.registerAgentProfile(50, "chat", "some metadata 1");
        revToken.approve(address(market), 500 ether);
        vm.stopPrank();

        vm.startPrank(agent_2);
        market.registerAgentProfile(50, "chat", "some metadata 2");
        vm.stopPrank();

        vm.startPrank(agent_3);
        market.registerAgentProfile(50, "chat", "some metadata 2");
        vm.stopPrank();

        uint256 reward = 50 ether;
        vm.startPrank(agent_1);
        market.registerTask(
            reward,
            0,
            "chat",
            "cheapest",
            "task payload"
        );
        market.registerTask(
            reward,
            0,
            "chat",
            "cheapest",
            "task payload"
        );
        vm.stopPrank();

        (uint256 requested1,
            uint256 assigned1,
            uint256 done1,
            uint256 rewards1
        ) = market.agentTotals(agent_2);
        assertEq(assigned1, 1, "Agent 2 should have 1 task assigned");

        (uint256 requested2,
            uint256 assigned2,
            uint256 done2,
            uint256 rewards2
        ) = market.agentTotals(agent_3);
        assertEq(assigned2, 1, "Agent 3 should have 1 task assigned");
    }

    function testRegisterTask() public {
        IPAssetRegistry IP_ASSET_REGISTRY = IPAssetRegistry(ipAssetRegistry);

        vm.startPrank(agent_1);
        market.registerAgentProfile(50, "chat", "some metadata");
        vm.stopPrank();

        vm.startPrank(agent_2);
        market.registerAgentProfile(10, "chat", "another agent");
        vm.stopPrank();

        vm.startPrank(agent_2);
        revToken.approve(address(market), 500 ether);
        uint256 expectedTokenId = agentNft.nextTokenId();
        address expectedIpId = IP_ASSET_REGISTRY.ipId(block.chainid, address(agentNft), expectedTokenId);
        uint256 expectedTaskId = market.tasksCounter();
        console.log("expectedTaskId", expectedTaskId);
        console.log("expectedIpId", expectedIpId);
        console.log("expectedChildTokenId", expectedTokenId);
        console.log("block.number", block.number);
        console.log("block.timestamp", block.timestamp);
        
        vm.expectEmit(true, true, true, false); // TODO: fix checkData
        emit TaskAssigned(agent_2, agent_1,  expectedTaskId, MarketLib.Task({
            id: expectedTaskId,
            contextId: expectedTaskId,
            timestamp: block.timestamp,
            blockNumber: block.number,
            reward: 50 ether, // cause that's the assigned agent's fee
            requester: agent_2,
            agentId: agent_1,
            matchingStrategy: "broadcast",
            payload: "task payload",
            topic: "chat",
            childTokenId: expectedTokenId,
            childIpId: expectedIpId,
            tasksToAssign: 1,
            tasksAssigned: 1,
            maxRepeatedPerAgent: 0
        }));

        uint256 reward = 100 ether;
        market.registerTask(
            reward,
            0,
            "chat",
            "broadcast",
            "task payload"
        );

        uint256 marketBalance = revToken.balanceOf(address(market));
        assertEq(marketBalance, reward, "Market contract should hold the reward");

        vm.stopPrank();
    }
    
    function testSendResult() public {
        vm.startPrank(agent_1);
        market.registerAgentProfile(100 ether, "chat", "metadataA");
        vm.stopPrank();

        vm.startPrank(agent_2);
        market.registerAgentProfile(20, "chat", "metadataB");
        vm.stopPrank();

        uint256 rewardAmount = 100 ether;

        vm.startPrank(agent_2);
        revToken.approve(address(market), rewardAmount);

        market.registerTask(
            rewardAmount,
            0,
            "chat",
            "broadcast",
            "someTaskPayload"
        );

        vm.stopPrank();

        vm.startPrank(agent_1);
        uint256 assignedTaskId = 1;

        string memory resultJSON = "{\"status\":\"done\"}";

        vm.expectEmit(true, true, true, true);
        emit TaskResultSent(agent_2, agent_1, assignedTaskId, MarketLib.TaskResult({
            id: assignedTaskId,
            timestamp: block.timestamp,
            blockNumber: block.number,
            result: resultJSON
        }));

        market.sendResult(assignedTaskId, resultJSON);
        vm.stopPrank();

        (bool exists,            // ensures we know if the agent is registered
        address id, // agent's wallet
        address ipAssetId,
        uint256 fee,            // how much an agent charges for the assigned tasks
        uint256 canNftTokenId,
        uint256 licenceTermsId,
        bytes32 topic,           // e.g. "tweet", "discord", ...
        string memory metadata) = market.agents(agent_1);

        // Check that Agent's 1 IP Account now has 100 WIPs in its balance.
        assertEq(revToken.balanceOf(ipAssetId), 100 ether);

        (uint256 requested,
            uint256 assigned,
            uint256 done,
            uint256 rewards
        ) = market.agentTotals(agent_1);
        assertEq(requested, 0, "AgentA never requested tasks");
        assertEq(assigned, 1, "AgentA should have 1 assigned task");
        assertEq(done, 1, "AgentA should have done 1 task");
        assertEq(rewards, 100 ether, "AgentA's total rewards mismatch");

        (uint256 marketDone, uint256 marketRewards) = market.marketTotals();
        assertEq(marketDone, 1, "marketTotals done mismatch");
        assertEq(marketRewards, 100 ether, "marketTotals rewards mismatch");
    }


    event RegisteredAgent(address indexed agent, MarketLib.AgentInfo agentInfo);
    event TaskAssigned(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.Task task);
    event TaskResultSent(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.TaskResult taskResult);
}
