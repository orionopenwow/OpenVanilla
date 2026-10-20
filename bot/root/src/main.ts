import { rootServer, RootBotStartState } from "@rootsdk/server-bot";
import { runSetup } from "./setup";

// On start (in DevHost from Setup_Root.bat, or when installed in a community) the bot builds or tops up
// the Open Vanilla layout, then stays idle. Nothing here runs on a timer or answers messages yet.
async function onStarting(_state: RootBotStartState) {
  runSetup().catch((e) => console.error("[Open Vanilla setup] crashed:", e));
}

(async () => {
  await rootServer.lifecycle.start(onStarting);
})();
