import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";
const INPUT_ACK = "firstmate-opencode-guard-input-accepted";

let skipNextIdle = false;

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let inputError = null;
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.stdin.on("error", (error) => {
      inputError = error;
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => {
      setImmediate(() => resolve({ code: code ?? 0, stdout, stderr, inputError }));
    });
    if (input) {
      setImmediate(() => {
        if (child.stdin.destroyed) {
          inputError = new Error("guard process closed stdin before input delivery");
          return;
        }
        child.stdin.end(input);
      });
    } else {
      child.stdin.end();
    }
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

async function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  const result = await runProcess(
    `${root}/bin/fm-turnend-guard.sh`,
    ["--opencode"],
    '{"stop_hook_active":false}',
  );
  if (!result.inputError && result.stdout.trim() === INPUT_ACK) return result;
  const detail = result.inputError?.code ? ` (${result.inputError.code})` : "";
  const failure = result.inputError
    ? `the guard process closed stdin${detail}`
    : "the guard process did not acknowledge the payload";
  return {
    ...result,
    code: 2,
    stderr:
      `OpenCode turn-end guard could not confirm input delivery because ${failure}.\n` +
      "The supervision state was not checked, so this turn must remain visible for recovery.\n" +
      result.stderr,
  };
}

async function letWatchArmRun(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return false;
  const status = await coordinator.ensureArmed(sessionID, client);
  return status === "armed" || status === "wake" || status === "failed";
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);

  return {
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      if (skipNextIdle) {
        skipNextIdle = false;
        return;
      }

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      if (await letWatchArmRun(sessionID, client)) return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
          },
        });
        skipNextIdle = true;
      } catch {
        skipNextIdle = false;
      }
    },
  };
};
