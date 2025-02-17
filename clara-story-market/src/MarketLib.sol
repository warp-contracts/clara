// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library MarketLib {

    struct AgentInfo {
        bool exists;            // ensures we know if the agent is registered
        address id; // agent's wallet
        address ipAssetId;
        uint256 fee;            // how much an agent charges for the assigned tasks
        uint256 canNftTokenId;
        uint256 licenceTermsId;
        bytes32 topic;           // e.g. "tweet", "discord", ...
        string metadata;        // arbitrary JSON or IPFS/Arweave txId?
    }

    struct AgentTotals {
        uint256 requested; // how many tasks this agent requested
        uint256 assigned;  // how many tasks have been assigned to this agent
        uint256 done;      // how many tasks the agent has completed
        uint256 rewards;   // how many tokens the agent has earned
    }

    struct MarketTotals {
        uint256 done;      // total tasks completed across all agents
        uint256 rewards;   // total rewards paid across all agents
    }

    struct Task {
        uint256 id;                  // unique task ID 
        uint256 contextId;           // used in chat to group tasks
        uint256 timestamp;          // block.timestamp
        uint256 blockNumber;        // block.number// who created the task
        uint256 reward;             // reward for fulfilling the task
        uint256 childTokenId;
        uint256 tasksToAssign;
        uint256 tasksAssigned;
        uint256 maxRepeatedPerAgent;
        address requester;
        address agentId;             // the assigned agent 
        address childIpId;
        bytes32 matchingStrategy;    // e.g. "leastOccupied", "broadcast", "cheapest"
        bytes32 topic;               // e.g. "chat"
        string payload;             // arbitrary JSON or IPFS/Arweave txId?
    }

    struct TaskResult {
        uint256 id;
        uint256 timestamp;
        uint256 blockNumber;
        string result;          // arbitrary JSON or IPFS/Arweave txId?
    }
}
