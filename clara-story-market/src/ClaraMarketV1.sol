// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./QueueLib.sol";
import "./mocks/AgentNFT.sol";

import "./mocks/RevenueToken.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { ILicensingModule } from "@storyprotocol/core/interfaces/modules/licensing/ILicensingModule.sol";
import { IPAssetRegistry } from "@storyprotocol/core/registries/IPAssetRegistry.sol";
import { IPILicenseTemplate } from "@storyprotocol/core/interfaces/modules/licensing/IPILicenseTemplate.sol";
import { IRoyaltyModule } from "@storyprotocol/core/interfaces/modules/royalty/IRoyaltyModule.sol";
import { IRoyaltyWorkflows } from "@storyprotocol/periphery/interfaces/workflows/IRoyaltyWorkflows.sol";

import { PILFlavors } from "@storyprotocol/core/lib/PILFlavors.sol";
import { PILTerms } from "@storyprotocol/core/interfaces/modules/licensing/IPILicenseTemplate.sol";
// import {console} from "forge-std/console.sol";
import { RoyaltyPolicyLAP } from "@storyprotocol/core/modules/royalty/policies/LAP/RoyaltyPolicyLAP.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {MarketLib} from "./MarketLib.sol";

error UnknownTopic(bytes32 topic);
error UnknownMatchingStrategy(bytes32 strategy);
error AgentNotRegistered(address agent);
error AgentAlreadyRegistered(address agent);
error TaskNotFound(uint256 taskId);
error ValueNegative();
error NoAgentsMatchedForTask();

/**
 * @title ClaraMarketV1
 */
contract ClaraMarketV1 is Context, ERC721Holder {
    // constants
    bytes32 internal constant STRATEGY_BROADCAST = "broadcast";
    bytes32 internal constant STRATEGY_LEAST_OCCUPIED = "leastOccupied";
    bytes32 internal constant STRATEGY_CHEAPEST = "cheapest";
    bytes32 internal constant STRATEGY_MULTITASK = "multiTask";

    bytes32 internal constant TOPIC_TWEET = "tweet";
    bytes32 internal constant TOPIC_DISCORD = "discord";
    bytes32 internal constant TOPIC_TELEGRAM = "telegram";
    bytes32 internal constant TOPIC_NFT = "nft";
    bytes32 internal constant TOPIC_CHAT = "chat";
    bytes32 internal constant TOPIC_NONE = "none";
    
    address internal constant ZERO_ADDRESS = address(0);

    // viem.keccak256(toHex("RedStone.ClaraMarket.Storage"))
    bytes32 private constant STORAGE_LOCATION = 0x662d955f31e0cda1ca2e8148a249b0c86a4293138bfb4d882e692ec1f9dabd24;

    // public
    MarketLib.MarketTotals public marketTotals;
    mapping(address => MarketLib.AgentInfo) public agents;
    address[] public allAgents;
    uint256 public agentsLength;
    mapping(address => MarketLib.AgentTotals) public agentTotals;
    mapping(address => mapping(uint256 => uint256)) public multiTasksPerformed;
    mapping(address => mapping(uint256 => MarketLib.Task)) public agentInbox;
    using QueueLib for QueueLib.Queue;
    QueueLib.Queue public tasksQueue;

    IPAssetRegistry public immutable IP_ASSET_REGISTRY;
    ILicensingModule public immutable LICENSING_MODULE;
    IPILicenseTemplate public immutable PIL_TEMPLATE;
    RoyaltyPolicyLAP public immutable ROYALTY_POLICY_LAP;
    IRoyaltyWorkflows public immutable ROYALTY_WORKFLOWS;
    IRoyaltyModule public immutable ROYALTY_MODULE;
    
    uint256 public tasksCounter;
    uint256 public multiTaskCounter;

    RevenueToken public immutable REVENUE_TOKEN;
    AgentNFT public immutable AGENT_NFT;
    
    // internal
    mapping(bytes32 => bool) internal topics;
    mapping(bytes32 => bool) internal matchingStrategies;


    // events
    event RegisteredAgent(address indexed agent, MarketLib.AgentInfo agentInfo);
    event UpdatedAgent(address indexed agent, MarketLib.AgentInfo agentInfo);
    event TaskAssigned(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.Task task);
    event TaskResultSent(address indexed requestingAgent, address indexed assignedAgent, uint256 indexed taskId, MarketLib.TaskResult taskResult);

    constructor(
        address ipAssetRegistry,
        address licensingModule,
        address pilTemplate,
        address royaltyPolicyLAP,
        address royaltyWorkflows,
        address royaltyModule,
        address payable _revenueToken) {
        
        REVENUE_TOKEN = RevenueToken(_revenueToken);
        IP_ASSET_REGISTRY = IPAssetRegistry(ipAssetRegistry);
        LICENSING_MODULE = ILicensingModule(licensingModule);
        PIL_TEMPLATE = IPILicenseTemplate(pilTemplate);
        ROYALTY_POLICY_LAP = RoyaltyPolicyLAP(royaltyPolicyLAP);
        ROYALTY_WORKFLOWS = IRoyaltyWorkflows(royaltyWorkflows);
        ROYALTY_MODULE = IRoyaltyModule(royaltyModule);
        
        topics[TOPIC_TWEET] = true;
        topics[TOPIC_DISCORD] = true;
        topics[TOPIC_TELEGRAM] = true;
        topics[TOPIC_NFT] = true;
        topics[TOPIC_CHAT] = true;
        topics[TOPIC_NONE] = true;

        matchingStrategies[STRATEGY_BROADCAST] = true;
        matchingStrategies[STRATEGY_LEAST_OCCUPIED] = true;
        matchingStrategies[STRATEGY_CHEAPEST] = true;

        tasksCounter = 1;
        multiTaskCounter = 1;

        AGENT_NFT = new AgentNFT("CLARA AGENT IP NFT", "CAIN"); // not sure if CAIN is the best symbol :)
    }

    function getPaymentsAddr() external view returns (address) {
        return address(REVENUE_TOKEN);
    }

    function registerAgentProfile(
        uint256 _fee,
        bytes32 _topic,
        string calldata _metadata
    )
    external
    {
        require(agents[_msgSender()].exists == false, AgentAlreadyRegistered(_msgSender()));
        _assertTopic(_topic);
        require(_fee >= 0, ValueNegative());

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
        _dispatchTasksInternal();
        emit RegisteredAgent(_msgSender(), agents[_msgSender()]);
    }

    function updateAgentFee(uint256 _fee)
    external
    {
        require(agents[_msgSender()].exists == true, AgentNotRegistered(_msgSender()));
        require(_fee >= 0, ValueNegative());

        agents[_msgSender()].fee = _fee;
        _dispatchTasksInternal();
        emit UpdatedAgent(_msgSender(), agents[_msgSender()]);
    }

    function registerTask(
        uint256 _reward,
        uint256 _contextId,
        bytes32 _topic,
        bytes32 _matchingStrategy,
        string calldata _payload
    )
    external
    {
        _assertAgentRegistered();
        require(_reward >= 0, ValueNegative());
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
            agentId: ZERO_ADDRESS,
            matchingStrategy: _matchingStrategy,
            payload: _payload,
            topic: _topic,
            childTokenId: 0,
            childIpId: ZERO_ADDRESS,
            tasksToAssign: 1,
            tasksAssigned: 1,
            maxRepeatedPerAgent: 0
        });

        // locking Revenue Tokens on Market contract - allowance required!
        REVENUE_TOKEN.transferFrom(_msgSender(), address(this), _reward);
        tasksQueue.push(newTask);
        _dispatchTasksInternal();
    }

    function registerMultiTask(
        uint256 _tasksCount,
        uint256 _maxRewardPerTask,
        uint256 _maxRepeatedTasksPerAgent,
        bytes32 _topic,
        string calldata _payload
    )
    external
    {
        _assertAgentRegistered();
        require(_maxRewardPerTask >= 0, ValueNegative());
        _assertTopic(_topic);

        agentTotals[_msgSender()].requested += 1;

        MarketLib.Task memory newTask = MarketLib.Task({
            id: multiTaskCounter++,
            contextId: 0,
            timestamp: block.timestamp,
            blockNumber: block.number,
            reward: _maxRewardPerTask,
            requester: _msgSender(),
            agentId: ZERO_ADDRESS,
            matchingStrategy: STRATEGY_MULTITASK,
            payload: _payload,
            topic: _topic,
            childTokenId: 0,
            childIpId: ZERO_ADDRESS,
            tasksToAssign: _tasksCount,
            tasksAssigned: 0,
            maxRepeatedPerAgent: _maxRepeatedTasksPerAgent
        });

        // locking Revenue Tokens on Market contract - allowance required!
        tasksQueue.push(newTask);
        REVENUE_TOKEN.transferFrom(_msgSender(), address(this), _tasksCount * _maxRewardPerTask);
        _dispatchTasksInternal();
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
            TaskNotFound(_taskId)
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

    function _dispatchTasksInternal() internal {
        uint256 tasksQueueLength = tasksQueue.length();
        if (tasksQueueLength == 0) {
            return;
        }

        MarketLib.Task[] memory notMatchedTasks = new MarketLib.Task[](tasksQueueLength);
        uint256 notMatchedTasksCount = 0;
        
        for (uint256 idx = 0; idx < tasksQueueLength; idx++) {
            if (tasksQueue.isEmpty()) {
                // this should not happen, but better safe than sorry...
                return;
            }
            MarketLib.Task memory _task = tasksQueue.pop();

            if (_task.matchingStrategy == STRATEGY_BROADCAST) {
                // broadcast strategy => assign to all matching agents
                address[] memory matchedAgents = _filterAgentsWithTopicAndFee(
                    _task.reward,
                    _task.requester,
                    _task.topic
                );
                if (matchedAgents.length == 0) {
                    notMatchedTasks[notMatchedTasksCount++] = _task;
                } else {
                    uint256 rewardLeft = _task.reward;
                
                    for (uint256 k = 0; k < matchedAgents.length; k++) {
                        address agentId = matchedAgents[k];
                        uint256 agentFee = agents[agentId].fee;
                        if (rewardLeft >= agentFee) {
                            _storeAndSendTask(agentId, _task, agentFee);
                            rewardLeft -= agentFee;
                        } else {
                            break;
                        }
                    }
                }
            } else if (_task.matchingStrategy == STRATEGY_LEAST_OCCUPIED) {
                address chosen = _matchLeastOccupied(_task.reward, _task.requester, _task.topic);
                if (chosen != ZERO_ADDRESS) {
                    uint256 agentFee = agents[chosen].fee;
                    _storeAndSendTask(chosen, _task, agentFee);
                } else {
                    notMatchedTasks[notMatchedTasksCount++] = _task;
                }
            } else if (_task.matchingStrategy == STRATEGY_CHEAPEST) {
                address chosen = _matchCheapest(_task.reward, _task.requester, _task.topic);
                if (chosen != ZERO_ADDRESS) {
                    uint256 agentFee = agents[chosen].fee;
                    _storeAndSendTask(chosen, _task, agentFee);
                } else {
                    notMatchedTasks[notMatchedTasksCount++] = _task;
                }
            } else if (_task.matchingStrategy == STRATEGY_MULTITASK) {
                address[] memory matchedAgents = _filterAgentsWithTopicAndFee(
                    _task.reward,
                    _task.requester,
                    _task.topic
                );
                for (uint256 k = 0; k < matchedAgents.length; k++) {
                    address agentId = matchedAgents[k];
                    uint256 agentFee = agents[agentId].fee;
                    if (multiTasksPerformed[agentId][_task.id] < _task.maxRepeatedPerAgent) {
                        _task.tasksAssigned += 1;
                        multiTasksPerformed[agentId][_task.id] += 1;
                        _storeAndSendTask(agentId, _task, agentFee);
                        if (_task.tasksAssigned == _task.tasksToAssign) {
                            break;
                        }
                    }
                }
                
                // force the task to be put again in the queue
                if (_task.tasksAssigned < _task.tasksToAssign) {
                    notMatchedTasks[notMatchedTasksCount++] = _task;
                }
            }
        }
        
        // push the tasks that were not assigned back on queue
        if (notMatchedTasksCount > 0) {
            for (uint256 idx = 0; idx < notMatchedTasksCount; idx++) {
                tasksQueue.push(notMatchedTasks[idx]);
            }
        }
    }

    function _storeAndSendTask(
        address _agentId,
        MarketLib.Task memory originalTask,
        uint256 agentFee
    ) internal {
        originalTask.reward = agentFee;
        originalTask.agentId = _agentId;

        uint256 taskId = tasksCounter++;
        
        // TODO: optimize
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
            childIpId: ZERO_ADDRESS,
            tasksToAssign: originalTask.tasksToAssign,
            tasksAssigned: originalTask.tasksAssigned,
            maxRepeatedPerAgent: originalTask.maxRepeatedPerAgent
        });

        uint256 childTokenId = AGENT_NFT.mint(address(this));
        address childIpId = IP_ASSET_REGISTRY.register(block.chainid, address(AGENT_NFT), childTokenId);

        // mint a license token from the parent
        uint256 licenseTokenId = LICENSING_MODULE.mintLicenseTokens({
            licensorIpId: agents[_agentId].ipAssetId,
            licenseTemplate: address(PIL_TEMPLATE),
            licenseTermsId: agents[_agentId].licenceTermsId,
            amount: 1,
            receiver: address(this),
            royaltyContext: "", // for PIL, royaltyContext is empty string
            maxMintingFee: 0,
            maxRevenueShare: 0
        });

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

        agentInbox[_agentId][finalTask.id] = finalTask;
        agentTotals[_agentId].assigned += 1;

        // transfer the NFT to the receiver so it owns the child IPA
        AGENT_NFT.transferFrom(address(this), _agentId, childTokenId);

        emit TaskAssigned(finalTask.requester, _agentId, finalTask.id, finalTask);
    }

    function _filterAgentsWithTopicAndFee(
        uint256 _reward,
        address _requesterId,
        bytes32 _topic
    ) internal view returns (address[] memory) {
        address[] memory temp = new address[](allAgents.length);
        uint256 count = 0;
        // console.log("All agents length", allAgents.length);

        for (uint256 i = 0; i < allAgents.length; i++) {
            // console.log("checking agent");
            address id_ = allAgents[i];
            MarketLib.AgentInfo memory agentInfo = agents[id_];

            if (!agentInfo.exists) {
                continue;
            }
            
            if (agentInfo.topic == TOPIC_NONE) {
                continue;
            }

            // topic must match
            if (agentInfo.topic != _topic) {
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

    function _matchLeastOccupied(
        uint256 _reward,
        address _requesterId,
        bytes32 _topic
    ) internal view returns (address) {
        address[] memory candidates = _filterAgentsWithTopicAndFee(_reward, _requesterId, _topic);
        if (candidates.length == 0) {
            return ZERO_ADDRESS;
        }

        uint256 minCount = type(uint256).max;
        address chosen = ZERO_ADDRESS;

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
        bytes32 _topic
    ) internal view returns (address) {
        address[] memory candidates = _filterAgentsWithTopicAndFee(_reward, _requesterId, _topic);
        if (candidates.length == 0) {
            return ZERO_ADDRESS;
        }

        uint256 minFee = type(uint256).max;
        uint256 minAssigned = type(uint256).max;
        address chosen = ZERO_ADDRESS;

        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 fee_ = agents[candidates[i]].fee;
            uint256 assigned_ = agentTotals[candidates[i]].assigned;
            if (fee_ <= minFee && assigned_ < minAssigned) {
                minFee = fee_;
                minAssigned = assigned_;
                chosen = candidates[i];
            }
        }

        return chosen;
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

    function _assertTopic(bytes32 _topic) internal view {
        require(topics[_topic], UnknownTopic(_topic));
    }

    function _assertMatchingStrategy(bytes32 _matchingStrategy) internal view {
        require(matchingStrategies[_matchingStrategy], UnknownMatchingStrategy(_matchingStrategy));
    }

    function _assertAgentRegistered() internal view {
        require(agents[_msgSender()].exists, AgentNotRegistered(_msgSender()));
    }

}
