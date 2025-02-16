// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./mocks/AgentNFT.sol";
import "./mocks/RevenueToken.sol";

import { IPAssetRegistry } from "@storyprotocol/core/registries/IPAssetRegistry.sol";
import { IRoyaltyWorkflows } from "@storyprotocol/periphery/interfaces/workflows/IRoyaltyWorkflows.sol";
import { ILicensingModule } from "@storyprotocol/core/interfaces/modules/licensing/ILicensingModule.sol";
import { PILFlavors } from "@storyprotocol/core/lib/PILFlavors.sol";
import { PILTerms } from "@storyprotocol/core/interfaces/modules/licensing/IPILicenseTemplate.sol";
import { IPILicenseTemplate } from "@storyprotocol/core/interfaces/modules/licensing/IPILicenseTemplate.sol";
import { IRoyaltyModule } from "@storyprotocol/core/interfaces/modules/royalty/IRoyaltyModule.sol";
import { RoyaltyPolicyLAP } from "@storyprotocol/core/modules/royalty/policies/LAP/RoyaltyPolicyLAP.sol";

import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {MarketLib} from "./MarketLib.sol";
import {console} from "forge-std/console.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/**
 * @title ClaraMarketV1
 */
contract ClaraMarketV1 is Context, ERC721Holder {
    // constants
    bytes32 internal constant BROADCAST = keccak256(abi.encodePacked("broadcast"));
    bytes32 internal constant LEAST_OCCUPIED = keccak256(abi.encodePacked("leastOccupied"));
    bytes32 internal constant CHEAPEST = keccak256(abi.encodePacked("cheapest"));
    bytes32 internal constant CHAT_TOPIC = keccak256(abi.encodePacked("chat"));
    bytes32 internal constant NONE_TOPIC = keccak256(abi.encodePacked("none"));

    // public
    MarketLib.MarketTotals public marketTotals;
    mapping(address => MarketLib.AgentInfo) public agents;
    address[] public allAgents;
    uint256 public agentsLength;
    mapping(address => MarketLib.AgentTotals) public agentTotals;
    mapping(address => mapping(uint256 => MarketLib.Task)) public agentInbox;

    IPAssetRegistry public immutable IP_ASSET_REGISTRY;
    ILicensingModule public immutable LICENSING_MODULE;
    IPILicenseTemplate public immutable PIL_TEMPLATE;
    RoyaltyPolicyLAP public immutable ROYALTY_POLICY_LAP;
    IRoyaltyWorkflows public immutable ROYALTY_WORKFLOWS;
    IRoyaltyModule public immutable ROYALTY_MODULE;

    RevenueToken public immutable REVENUE_TOKEN;
    AgentNFT public immutable AGENT_NFT;
    
    // internal
    mapping(string => bool) internal topics;
    mapping(string => bool) internal matchingStrategies;

    // private
    uint256 public tasksCounter;

    // events
    event RegisteredAgent(address indexed agent, MarketLib.AgentInfo agentInfo);
    event TaskAssigned(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.Task task);
    event TaskResultSent(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.TaskResult taskResult);

    constructor(
    // "IPAssetRegistry": "0x77319B4031e6eF1250907aa00018B8B1c67a244b",
        address ipAssetRegistry,
    // "LicensingModule": "0x04fbd8a2e56dd85CFD5500A4A4DfA955B9f1dE6f",
        address licensingModule,
    // "PILicenseTemplate": "0x2E896b0b2Fdb7457499B56AAaA4AE55BCB4Cd316",
        address pilTemplate,
    // "RoyaltyPolicyLAP": "0xBe54FB168b3c982b7AaE60dB6CF75Bd8447b390E",
        address royaltyPolicyLAP,
    // "RoyaltyWorkflows": "0x9515faE61E0c0447C6AC6dEe5628A2097aFE1890",
        address royaltyWorkflows,
    //  "RoyaltyModule": "0xD2f60c40fEbccf6311f8B47c4f2Ec6b040400086",
        address royaltyModule,
    // "WIP": "0x1514000000000000000000000000000000000000"
        address payable _revenueToken) {
        require(_revenueToken != address(0), "Invalid token address");
        REVENUE_TOKEN = RevenueToken(_revenueToken);
        IP_ASSET_REGISTRY = IPAssetRegistry(ipAssetRegistry);
        LICENSING_MODULE = ILicensingModule(licensingModule);
        PIL_TEMPLATE = IPILicenseTemplate(pilTemplate);
        ROYALTY_POLICY_LAP = RoyaltyPolicyLAP(royaltyPolicyLAP);
        ROYALTY_WORKFLOWS = IRoyaltyWorkflows(royaltyWorkflows);
        ROYALTY_MODULE = IRoyaltyModule(royaltyModule);
        
        topics["tweet"] = true;
        topics["discord"] = true;
        topics["telegram"] = true;
        topics["nft"] = true;
        topics["chat"] = true;
        topics["none"] = true;

        matchingStrategies["broadcast"] = true;
        matchingStrategies["leastOccupied"] = true;
        matchingStrategies["cheapest"] = true;

        tasksCounter = 1;

        AGENT_NFT = new AgentNFT("CLARA AGENT IP NFT", "CAIN"); // not sure if CAIN is the best symbol :)
    }

    function _assertTopic(string memory _topic) internal view {
        require(topics[_topic], "Unknown topic");
    }

    function _assertMatchingStrategy(string memory _matchingStrategy) internal view {
        require(matchingStrategies[_matchingStrategy], "Unknown matching strategy");
    }

    function _assertAgentRegistered() internal view {
        require(agents[_msgSender()].exists, "Agent not registered");
    }

    function registerAgentProfile(
        uint256 _fee,
        string calldata _topic,
        string calldata _metadata
    )
    external
    {
        _assertTopic(_topic);
        require(_fee >= 0, "Fee cannot be negative");
        require(agents[_msgSender()].exists == false, "Agent already registered");

        uint256 tokenId = AGENT_NFT.mint(address(this));
        address ipId = IP_ASSET_REGISTRY.register(block.chainid, address(AGENT_NFT), tokenId);
        uint256 licenseTermsId = PIL_TEMPLATE.registerLicenseTerms(
            PILFlavors.commercialRemix({
            mintingFee: 0,
            commercialRevShare: 100 * 10 ** 6, // 100% - i.e. all royalties for the tasks (childIPs) are sent to the Agent assigned to this task
            royaltyPolicy: address(ROYALTY_POLICY_LAP),
            currencyToken: address(REVENUE_TOKEN)
        }));
        
        // attach the license terms to the IP Asset
        LICENSING_MODULE.attachLicenseTerms(ipId, address(PIL_TEMPLATE), licenseTermsId);

        // transfer the NFT to the receiver so it owns the IPA
        AGENT_NFT.transferFrom(address(this), _msgSender(), tokenId);
        
        _registerAgent();
        agents[_msgSender()] = MarketLib.AgentInfo({
            exists: true,
            id: _msgSender(),
            topic: _topic,
            fee: _fee,
            metadata: _metadata,
            ipAssetId: ipId,
            canNftTokenId: tokenId,
            licenceTermsId: licenseTermsId

        });
        emit RegisteredAgent(_msgSender(), agents[_msgSender()]);
    }

    function registerTask(
        uint256 _reward,
        uint256 _contextId,
        string calldata _topic,
        string calldata _matchingStrategy,
        string calldata _payload
    )
    external
    {
        _assertAgentRegistered();
        require(_reward > 0, "Reward must be positive");
        _assertTopic(_topic);
        _assertMatchingStrategy(_matchingStrategy);

        agentTotals[_msgSender()].requested += 1;

        MarketLib.Task memory newTask = MarketLib.Task({
            id: 0,
            contextId: _contextId == 0 ? 0 : _contextId,
            timestamp: block.timestamp,
            blockNumber: block.number,
            reward: _reward,
            requester: _msgSender(),
            agentId: address(0),
            matchingStrategy: _matchingStrategy,
            payload: _payload,
            topic: _topic,
            childTokenId: 0,
            childIpId: address(0)
        });

        // locking Revenue Tokens on Market contract - allowance required!
        REVENUE_TOKEN.transferFrom(_msgSender(), address(this), _reward);
        _dispatchTasksInternal(newTask);
    }

    function sendResult(
        uint256 _taskId,
        string calldata _resultJSON
    )
    external
    {
        _assertAgentRegistered();

        MarketLib.Task memory originalTask = agentInbox[_msgSender()][_taskId];
        require(
            originalTask.id != 0,
            "Task not found in agent inbox or already completed"
        );

        delete agentInbox[_msgSender()][_taskId];

        agentTotals[_msgSender()].done += 1;
        agentTotals[_msgSender()].rewards += originalTask.reward;

        marketTotals.done += 1;
        marketTotals.rewards += originalTask.reward;

        MarketLib.TaskResult memory taskResult = MarketLib.TaskResult({
            id: originalTask.id,
            timestamp: block.timestamp,
            blockNumber: block.number,
            result: _resultJSON
        });

        // agentResults[originalTask.requester][originalTask.id] = taskResult;
        // Transfer tokens from contract balance to the agent
        //_transferTokens(_msgSender(), originalTask.reward);
        REVENUE_TOKEN.approve(address(ROYALTY_MODULE), originalTask.reward);
        ROYALTY_MODULE.payRoyaltyOnBehalf(originalTask.childIpId, address(this), address(REVENUE_TOKEN), originalTask.reward);

        address[] memory childIpIds = new address[](1);
        address[] memory royaltyPolicies = new address[](1);
        address[] memory currencyTokens = new address[](1);
        childIpIds[0] = originalTask.childIpId;
        royaltyPolicies[0] = address(ROYALTY_POLICY_LAP);
        currencyTokens[0] = address(REVENUE_TOKEN);
        uint256[] memory amountsClaimed = ROYALTY_WORKFLOWS.claimAllRevenue({
            ancestorIpId: agents[_msgSender()].ipAssetId,
            claimer: agents[_msgSender()].ipAssetId,
            childIpIds: childIpIds,
            royaltyPolicies: royaltyPolicies,
            currencyTokens: currencyTokens
        });
        
        emit TaskResultSent(originalTask.requester, _msgSender(), originalTask.id, taskResult);
    }

    function _dispatchTasksInternal(MarketLib.Task memory _task) internal {
        bytes32 strategy = keccak256(abi.encodePacked(_task.matchingStrategy));

        if (strategy == BROADCAST) {
            // broadcast strategy => assign to all matching agents
            console.log("broadcast");
            address[] memory matchedAgents = _matchBroadcast(
                _task.reward,
                _task.requester,
                _task.topic
            );
            console.log(matchedAgents.length);
            require(matchedAgents.length > 0, "Could not match any agents for broadcast mode");
            uint256 rewardLeft = _task.reward;
        
            for (uint256 k = 0; k < matchedAgents.length; k++) {
                address agentId = matchedAgents[k];
                uint256 agentFee = agents[agentId].fee;
                if (rewardLeft >= agentFee) {
                    _storeAndSendTask(agentId, _task, agentFee);
                    rewardLeft -= agentFee;
                } else {
                    return;
                }
            }
        } else if (strategy == LEAST_OCCUPIED) {
            address chosen = _matchLeastOccupied(_task.reward, _task.requester, _task.topic);
            require(chosen != address(0), "Could not match agent for least occupied mode");
            uint256 agentFee = agents[chosen].fee;
            _storeAndSendTask(chosen, _task, agentFee);
        } else if (strategy == CHEAPEST) {
            address cheapest = _matchCheapest(_task.reward, _task.requester, _task.topic);
            require(cheapest != address(0), "Could not match agent for cheapest mode");
            uint256 agentFee = agents[cheapest].fee;
            _storeAndSendTask(cheapest, _task, agentFee);
        }
    }

    function _storeAndSendTask(
        address _agentId,
        MarketLib.Task memory originalTask,
        uint256 agentFee
    ) internal {
        console.log("_storeAndSendTask");
        originalTask.reward = agentFee;
        originalTask.agentId = _agentId;

        uint256 taskId = tasksCounter++;
        MarketLib.Task memory finalTask = MarketLib.Task({
            id: taskId,
            contextId: originalTask.contextId == 0 ? taskId : originalTask.contextId,
            timestamp: originalTask.timestamp,
            blockNumber: originalTask.blockNumber,
            reward: originalTask.reward,
            requester: originalTask.requester,
            agentId: originalTask.agentId,
            matchingStrategy: originalTask.matchingStrategy,
            payload: originalTask.payload,
            topic: originalTask.topic,
            childTokenId: 0,
            childIpId: address(0)
        });

        uint256 childTokenId = AGENT_NFT.mint(address(this));
        address childIpId = IP_ASSET_REGISTRY.register(block.chainid, address(AGENT_NFT), childTokenId);

        // mint a license token from the parent
        console.log("mintLicenseTokens");
        console.log(address(this));
        console.log("ipAssetId", agents[_agentId].ipAssetId);
        console.log("pilTemplate", address(PIL_TEMPLATE));
        console.log("licenceTermsId", agents[_agentId].licenceTermsId);
        
        uint256 licenseTokenId = LICENSING_MODULE.mintLicenseTokens({
            licensorIpId: agents[_agentId].ipAssetId,
            licenseTemplate: address(PIL_TEMPLATE),
            licenseTermsId: agents[_agentId].licenceTermsId,
            amount: 1,
        // mint the license token to this contract so it can
        // use it to register as a derivative of the parent
            receiver: address(this),
            royaltyContext: "", // for PIL, royaltyContext is empty string
            maxMintingFee: 0,
            maxRevenueShare: 0
        });
        console.log("after mintLicenseTokens");

        uint256[] memory licenseTokenIds = new uint256[](1);
        licenseTokenIds[0] = licenseTokenId;

        // register the new child IPA as a derivative
        // of the parent
        LICENSING_MODULE.registerDerivativeWithLicenseTokens({
            childIpId: childIpId,
            licenseTokenIds: licenseTokenIds,
            royaltyContext: "", // empty for PIL
            maxRts: 0
        });
        finalTask.childIpId = childIpId;
        finalTask.childTokenId = childTokenId;

        // transfer the NFT to the receiver so it owns the child IPA
        console.log("Before transfer");
        console.log(_agentId);
        AGENT_NFT.transferFrom(address(this), _agentId, childTokenId);
        console.log("after transfer");
        
        agentInbox[_agentId][finalTask.id] = finalTask;
        agentTotals[_agentId].assigned += 1;

        emit TaskAssigned(finalTask.requester, _agentId, finalTask.id, finalTask);
    }

    function _filterAgentsWithTopicAndFee(
        uint256 _reward,
        address _requesterId,
        string memory _topic
    ) internal view returns (address[] memory) {
        address[] memory temp = new address[](allAgents.length);
        uint256 count = 0;
        console.log("All agents length", allAgents.length);

        bytes32 topic = keccak256(abi.encodePacked(_topic));

        for (uint256 i = 0; i < allAgents.length; i++) {
            console.log("checking agent");
            address id_ = allAgents[i];
            MarketLib.AgentInfo memory agentInfo = agents[id_];

            bytes32 agentTopic = keccak256(abi.encodePacked(agentInfo.topic));
            if (!agentInfo.exists) {
                continue;
            }
            
            if (agentTopic == NONE_TOPIC) {
                continue;
            }

            // topic must match
            if (agentTopic != topic) {
                continue;
            }

            // fee must be <= reward
            if (agentInfo.fee > _reward) {
                continue;
            }

            // cannot assign to self
            if (_requesterId == id_) {
                continue;
            }

            temp[count++] = id_;
        }

        address[] memory filtered = new address[](count);
        for (uint256 j = 0; j < count; j++) {
            filtered[j] = temp[j];
        }
        return filtered;
    }

    function _matchBroadcast(
        uint256 _reward,
        address _requesterId,
        string memory _topic
    ) internal view returns (address[] memory) {
        return _filterAgentsWithTopicAndFee(_reward, _requesterId, _topic);
    }

    function _matchLeastOccupied(
        uint256 _reward,
        address _requesterId,
        string memory _topic
    ) internal view returns (address) {
        address[] memory candidates = _filterAgentsWithTopicAndFee(_reward, _requesterId, _topic);
        if (candidates.length == 0) {
            return address(0);
        }

        uint256 minCount = type(uint256).max;
        address chosen = address(0);

        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 inboxCount = _agentInboxCount(candidates[i]);
            if (inboxCount < minCount) {
                minCount = inboxCount;
                chosen = candidates[i];
            }
        }
        return chosen;
    }

    function _matchCheapest(
        uint256 _reward,
        address _requesterId,
        string memory _topic
    ) internal view returns (address) {
        address[] memory candidates = _filterAgentsWithTopicAndFee(_reward, _requesterId, _topic);
        if (candidates.length == 0) {
            return address(0);
        }

        uint256 minFee = type(uint256).max;
        address chosen = address(0);

        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 fee_ = agents[candidates[i]].fee;
            if (fee_ < minFee) {
                minFee = fee_;
                chosen = candidates[i];
            }
        }

        return chosen;
    }

    function _transferTokens(address to, uint256 amount) private {
        require(to != address(0), "Cannot transfer to zero address");
        bool ok = REVENUE_TOKEN.transfer(to, amount);
        require(ok, "Token transfer failed");
    }

    function _agentInboxCount(address _agentId) private view returns (uint256) {
        MarketLib.AgentTotals memory tot = agentTotals[_agentId];
        // approximate:
        uint256 currentlyInInbox = tot.assigned - tot.done;
        return currentlyInInbox;
    }

    function _registerAgent() internal {
        // Add only if new
        if (!agents[_msgSender()].exists) {
            agents[_msgSender()].exists = true;
            allAgents.push(_msgSender());
            agentsLength++;
        }
    }

    function getPaymentsAddr() external view returns (address) {
        return address(REVENUE_TOKEN);
    }

}
