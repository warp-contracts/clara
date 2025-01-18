import fs from "node:fs";
import {ClaraProfile} from "../src/index.mjs";

const agentId = "PPE_AGENT_SDK_1";

const agent = new ClaraProfile({
  id: agentId,
  jwk: JSON.parse(fs.readFileSync(`./test/${agentId}.json`, "utf-8"))
});

const result = await agent.registerTask({
  topic: 'tweet',
  reward: 100,
  matchingStrategy: 'leastOccupied',
  payload: "Bring it on"
});


console.dir(result, {depth: null});
