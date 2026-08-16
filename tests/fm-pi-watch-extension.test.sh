#!/usr/bin/env bash
# Tests for the tracked Pi primary watcher extension and Pi secondmate wiring.
#
# Never write an apostrophe inside the Node driver heredocs below, comments
# included. Each driver sits inside an out=$(...) command substitution, and
# stock macOS Bash 3.2 tracks quote characters straight through a heredoc body
# while Bash 4 and later do not. One stray apostrophe makes that scanner
# swallow everything up to the next one, hiding the double quotes in between,
# so the file stops parsing on 3.2 while parsing fine everywhere else. The
# reported error lands thousands of lines away from the apostrophe that caused
# it. The macos-stock-bash CI job is what catches this; write "the stub in this
# driver" rather than "this driver's stub" and it never comes up.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-checkpoint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-checkpoint-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-watch-extension)
CHECKPOINT_MODULE=$(fm_checkpoint_module "$TMP_ROOT")
EXT="$ROOT/.pi/extensions/fm-primary-pi-watch.ts"
# Node 24 warns when these test-only dynamic imports load tracked ESM plugins
# from a clean checkout with no tracked .opencode/package.json. The warning is
# unrelated to plugin output, which the assertions intentionally require empty.
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_tracked_extension_present_and_self_hashing() {
  local text expected_config_source
  expected_config_source="config_dir=\\\"\${FM_CONFIG_OVERRIDE:-\$FM_HOME/config}\\\""
  assert_present "$EXT" "tracked Pi primary watcher extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" "fm_watch_arm_pi" "tracked extension missing tool name"
  assert_contains "$text" "fm-watch-arm-pi" "tracked extension missing command name"
  assert_contains "$text" "fm-watch-arm.sh" "tracked extension missing watcher arm"
  assert_contains "$text" "sendUserMessage" "tracked extension missing Pi wake API"
  assert_contains "$text" "deliverAs: \"followUp\"" "tracked extension missing followUp delivery"
  assert_contains "$text" ".pi-watch-extension-loaded" "tracked extension missing loaded marker"
  assert_contains "$text" 'createHash("sha256").update(readFileSync(extensionFile)).digest("hex")' "tracked extension does not self-hash its own content for extensionVersion"
  assert_contains "$text" 'fileURLToPath(import.meta.url)' "tracked extension does not self-locate via import.meta.url"
  assert_contains "$text" 'type LockOwnership = "owned" | "missing" | "other"' "tracked extension does not distinguish missing lock from another owner"
  assert_contains "$text" "readFileSync(\`\${state}/.lock\`" "tracked extension does not read the effective session lock"
  assert_contains "$text" 'return pidAlive(lockPid) ? "other" : "missing"' "tracked extension does not allow a pre-lock load marker"
  assert_contains "$text" 'spawnSync("ps", ["-l", "-p", pid]' "tracked extension lacks the Cygwin-compatible parent lookup"
  assert_contains "$text" 'if (lockOwnership() === "other") return' "tracked extension overwrites another live session marker"
  assert_contains "$text" "writeFileSync(marker, \`\${extensionVersion}\\n\${process.pid}\\n\`)" "tracked extension does not write the content version and process marker"
  assert_contains "$text" "const config = process.env.FM_CONFIG_OVERRIDE" "tracked extension missing effective config resolution"
  assert_contains "$text" "FM_CONFIG_OVERRIDE: config" "tracked extension does not pass the effective config to the watcher arm"
  assert_contains "$text" "FM_WATCH_ARM_SCRIPT: armScript" "tracked extension does not pass the effective watcher arm script"
  assert_contains "$text" "$expected_config_source" "tracked extension does not source the effective x-mode config"
  assert_contains "$text" "exec \\\"\$FM_WATCH_ARM_SCRIPT\\\" --restart" "tracked extension does not restart into a Pi-owned watcher child"
  assert_contains "$text" 'label: "Arm firstmate watcher"' "tracked extension tool is missing its human-readable label"
  assert_contains "$text" 'parameters: Type.Object({})' "tracked extension tool is not using Pi's canonical TypeBox schema"
  assert_contains "$text" 'content: [{ type: "text", text: result.message }]' "tracked extension tool is missing Pi text content"
  assert_contains "$text" 'details: result' "tracked extension tool is missing structured result details"
  assert_contains "$text" 'ctx.ui.notify' "tracked extension command does not notify through Pi's UI"
  assert_contains "$text" 'process.once("exit", cleanupOnProcessExit)' "tracked extension lacks clean-process-exit cleanup"
  assert_not_contains "$text" "[ -f config/x-mode.env ]" "tracked extension kept a repo-relative x-mode config path"
  pass "Pi primary watcher extension is tracked, self-hashing, and self-locating"
}

test_spawn_template_mentions_pi_watch_placeholder() {
  local text
  text=$(cat "$ROOT/bin/fm-spawn.sh")
  assert_contains "$text" "-e __PITURNEND__ -e __PIWATCH__" "Pi secondmate launch template does not include both primary extensions"
  assert_contains "$text" "\$PROJ_ABS/.pi/extensions/fm-primary-pi-watch.ts" "fm-spawn does not point the Pi secondmate watch placeholder at the tracked extension"
  assert_not_contains "$text" "fm-pi-watch-extension.sh" "fm-spawn should no longer generate the Pi watch extension before launch"
  assert_contains "$text" "__PITURNEND__" "fm-spawn does not replace the Pi turn-end guard extension placeholder"
  assert_contains "$text" "__PIWATCH__" "fm-spawn does not replace the Pi watch extension placeholder"
  pass "Pi secondmate launch wiring includes both tracked primary extensions"
}

test_pi_extension_reports_external_healthy_watcher() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-external-healthy-root"
  home="$TMP_ROOT/pi-external-healthy-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
let handler = null;
let notification = "";
let prompt = "";
const delivered = latch("pi external-healthy wake delivery");
const pi = {
  on() {},
  registerCommand(name, options) {
    if (name === "fm-watch-arm-pi") handler = options.handler;
  },
  registerTool() {},
  sendUserMessage: async (message) => {
    prompt = message;
    delivered.signal();
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!handler) {
  console.error("Pi watch command was not registered");
  process.exit(1);
}
const result = await handler("", {
  ui: {
    notify(message) {
      notification = message;
    },
  },
});
if (result !== undefined) {
  console.error(`Pi command returned a value: ${String(result)}`);
  process.exit(1);
}
if (!notification.includes("started Pi extension arm child")) {
  console.error(notification);
  process.exit(1);
}
// The follow-up wake arrives through the sendUserMessage stub in this driver,
// so the stub is the checkpoint. Nothing here needs to know how long the arm
// child takes to report its external healthy watcher.
await delivered.reached;
if (!prompt.startsWith("\u2063FIRSTMATE_OP: v1 watcher: ")) {
  console.error(`untyped operational follow-up: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("FIRSTMATE WATCHER WAKE")) {
  console.error(`missing follow-up prompt: ${prompt}`);
  process.exit(1);
}
if (!prompt.includes("external healthy watcher")) {
  console.error(prompt);
  process.exit(1);
}
if (!prompt.includes("watcher: healthy pid=1")) {
  console.error(prompt);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi extension must surface an external healthy watcher as an owned-wake failure"
  [ -z "$out" ] || fail "Pi external-healthy test printed output: $out"
  pass "Pi extension reports external healthy watcher output"
}

test_pi_tool_returns_agent_tool_result() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-tool-result-root"
  home="$TMP_ROOT/pi-tool-result-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
if (tool.label !== "Arm firstmate watcher") throw new Error(`unexpected label: ${tool.label}`);
if (tool.parameters?.type !== "object") throw new Error("tool parameters are not a TypeBox object schema");
const metadata = [tool.description, tool.promptSnippet, ...(tool.promptGuidelines ?? [])].join("\n");
if (metadata.includes("Always use this tool")) throw new Error(`broad tool-selection metadata remained visible: ${metadata}`);
if (!tool.description.includes("first required Pi watcher cycle")) throw new Error(`tool description omitted the first-cycle condition: ${tool.description}`);
if (!tool.promptSnippet.includes("ordinary re-arming is automatic")) throw new Error(`tool snippet omitted automatic continuation: ${tool.promptSnippet}`);
if (!tool.promptGuidelines.some((guideline) => guideline.includes("ordinary signal, stale, check, or heartbeat handling"))) {
  throw new Error(`tool guidelines omitted ordinary-notification prevention: ${tool.promptGuidelines}`);
}
const result = await tool.execute("tool-call-1", {}, undefined, undefined, {});
if (!Array.isArray(result.content) || result.content[0]?.type !== "text") {
  throw new Error(`invalid tool content: ${JSON.stringify(result)}`);
}
if (!result.content[0].text.includes("started Pi extension arm child")) {
  throw new Error(`unexpected tool text: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("future ordinary re-arms are automatic")) {
  throw new Error(`initial tool result omitted automatic continuation guidance: ${result.content[0].text}`);
}
if (!result.content[0].text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`initial tool result omitted the repair-only condition: ${result.content[0].text}`);
}
if (result.details?.ok !== true || result.details?.message !== result.content[0].text) {
  throw new Error(`invalid tool details: ${JSON.stringify(result.details)}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi custom tool must expose first-cycle or repair-only metadata and return Pi's AgentToolResult shape"
  [ -z "$out" ] || fail "Pi tool-result test printed output: $out"
  pass "Pi custom tool exposes repair-only metadata and returns automatic-continuation guidance"
}

test_pi_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop bus out status
  repo="$TMP_ROOT/pi-redundant-tool-root"
  home="$TMP_ROOT/pi-redundant-tool-home"
  log="$TMP_ROOT/pi-redundant-tool.log"
  stop="$TMP_ROOT/pi-redundant-tool.stop"
  bus="$TMP_ROOT/pi-redundant-tool.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started Pi extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("Pi extension already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`redundant call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
// The arm child announces itself once its row is on disk, which is a stronger
// fact than the log file merely existing.
await bus.reached("armed");
// Left as a duration on purpose. The claim under test is that the redundant
// call started NO second child, and an absence is only observable across some
// span of time; there is no checkpoint for an event that must never happen.
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
bus.close();
EOF
)
  status=$?
  expect_code 0 "$status" "Pi redundant tool call must remain an ownership-based no-op with repair-only guidance"
  [ -z "$out" ] || fail "Pi redundant-call test printed output: $out"
  pass "Pi redundant tool call returns ownership guidance and spawns no second child"
}

test_pi_scheduled_retry_call_is_owned_noop() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-scheduled-retry-root"
  home="$TMP_ROOT/pi-scheduled-retry-home"
  log="$TMP_ROOT/pi-scheduled-retry.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=10000 FM_WATCH_REARM_RETRY_MAX_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
// The extension arms exactly one timer at the configured retry delay, and it
// does so at the moment the scheduled continuity retry starts existing. That
// creation is the checkpoint. The old loop hunted for the same moment by
// re-calling the tool until its wording changed, which both assumed the retry
// would appear within a second and made the tool call part of the search
// rather than the observation.
const retryScheduled = latch("pi scheduled continuity retry");
const nativeSetTimeout = globalThis.setTimeout;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_WATCH_REARM_RETRY_BASE_MS)) retryScheduled.signal();
  return nativeSetTimeout(callback, delay, ...args);
};
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-first", {}, undefined, undefined, {});
await retryScheduled.reached;
const redundant = await tool.execute("tool-call-during-retry", {}, undefined, undefined, {});
if (!redundant?.content[0]?.text.includes("Pi extension already owns a scheduled continuity retry; no manual re-arm needed")) {
  throw new Error(`scheduled retry did not return ownership-based no-op guidance: ${redundant?.content[0]?.text}`);
}
if (/^watcher: healthy\b/.test(redundant.content[0]?.text)) {
  throw new Error(`scheduled retry call overclaimed independent health: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`scheduled retry call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
// Left as a duration on purpose: the claim is that no second arm child was
// spawned, and there is no checkpoint for an event that must never occur.
await new Promise((resolve) => nativeSetTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`scheduled retry call spawned ${rows.length} arm children`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi scheduled-retry call must not duplicate the extension-owned retry"
  [ -z "$out" ] || fail "Pi scheduled-retry test printed output: $out"
  pass "Pi scheduled retry remains extension-owned after another tool call"
}

test_pi_actionable_close_starts_single_successor_before_delivery() {
  local repo home plugin log stop bus out status
  repo="$TMP_ROOT/pi-continuous-rearm-root"
  home="$TMP_ROOT/pi-continuous-rearm-home"
  log="$TMP_ROOT/pi-continuous-rearm.log"
  stop="$TMP_ROOT/pi-continuous-rearm.stop"
  bus="$TMP_ROOT/pi-continuous-rearm.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  printf 'confirmed %s\n' "$2" > "${FM_CHECKPOINT_BUS:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic actionable close\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch, openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
let deliveryStarted = false;
let rowsAtDelivery = 0;
const deliveryBegan = latch("pi wake delivery began");
let releaseDelivery = () => {};
const deliveryBlocked = new Promise((resolve) => {
  releaseDelivery = resolve;
});
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    rowsAtDelivery = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    deliveryStarted = true;
    deliveryBegan.signal();
    await deliveryBlocked;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-continuity", {}, undefined, undefined, {});
// Delivery entering the stub in this driver is the checkpoint. The successor
// arm row is written before delivery begins, so waiting on delivery already
// covers the row the old loop was separately polling for - and rowsAtDelivery
// below is what actually proves that ordering, not the loop condition.
await deliveryBegan.reached;
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (!deliveryStarted) throw new Error("wake delivery did not begin");
if (rowsAtDelivery !== 2) throw new Error(`wake delivery began before successor establishment (${rowsAtDelivery} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
// Left as a duration on purpose: this asserts that delivery is NOT confirmed
// while the prompt is still outstanding, and an absence needs a window.
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releaseDelivery();
// The confirming arm invocation announces itself, so the driver no longer has
// to guess that a second of polling is enough for it to appear.
await bus.reached("confirmed");
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi actionable close must start one successor before wake delivery settles"
  [ -z "$out" ] || fail "Pi continuous-rearm test printed output: $out"
  pass "Pi actionable close starts one successor before wake delivery settles"
}

test_pi_hung_successor_falls_back_to_typed_wake() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-hung-successor-root"
  home="$TMP_ROOT/pi-hung-successor-home"
  log="$TMP_ROOT/pi-hung-successor.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_PI_ARM_READY_TIMEOUT_MS=1000 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
const fallbackDelivered = latch("pi hung-successor fallback wake");
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    fallbackDelivered.signal();
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-hung-successor", {}, undefined, undefined, {});
// The fallback wake is delivered into the stub in this driver, so the stub is
// the checkpoint. This replaced a twenty-second budget that had to cover a
// readiness deadline plus two retries and was still only a guess.
await fallbackDelivered.reached;
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 4) throw new Error(`expected one successor plus two retries, got ${rows.length}: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
// Left as a duration on purpose: single-flight recovery is a claim that no
// further arm is launched, which an absence-window is the only way to check.
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi must deliver the actionable wake after bounded hung-successor recovery"
  [ -z "$out" ] || fail "Pi hung-successor test printed output: $out"
  pass "Pi hung successor falls back to one typed actionable wake"
}

test_pi_unretired_successor_falls_back_without_retry() {
  local repo home plugin log startup activate unretired retired release bus out status
  repo="$TMP_ROOT/pi-unretired-successor-root"
  home="$TMP_ROOT/pi-unretired-successor-home"
  log="$TMP_ROOT/pi-unretired-successor.log"
  startup="$TMP_ROOT/pi-unretired-successor.startup"
  activate="$TMP_ROOT/pi-unretired-successor.activate"
  unretired="$TMP_ROOT/pi-unretired-successor.unretired"
  retired="$TMP_ROOT/pi-unretired-successor.retired"
  release="$TMP_ROOT/pi-unretired-successor.release"
  bus="$TMP_ROOT/pi-unretired-successor.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  mkfifo "$activate"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'waiting\n' > "${FM_STARTUP_FILE:?}"
printf 'successor-startup %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
IFS= read -r _ < "${FM_ACTIVATE_FILE:?}"
trap 'printf "%s\n" "$$" > "${FM_RETIRED_FILE:?}"; printf "successor-retired %s\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf '%s\n' "$$" > "${FM_UNRETIRED_FILE:?}"
printf 'successor-unretired %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STARTUP_FILE="$startup" FM_ACTIVATE_FILE="$activate" FM_UNRETIRED_FILE="$unretired" FM_RETIRED_FILE="$retired" FM_RELEASE_FILE="$release" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const readinessTimer = { unref() {} };
let fireReadinessTimeout = null;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_PI_ARM_READY_TIMEOUT_MS) && fireReadinessTimeout === null) {
    fireReadinessTimeout = () => callback(...args);
    return readinessTimer;
  }
  return nativeSetTimeout(callback, delay, ...args);
};
globalThis.clearTimeout = (timer) => {
  if (timer !== readinessTimer) nativeClearTimeout(timer);
};
const { latch, openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}
let tool = null;
let prompt = "";
let rowsAtPrompt = 0;
let successorPidAtPrompt = "";
let successorAliveAtPrompt = false;
let sessionShutdown = () => {};
const fallbackDelivered = latch("pi unretired-successor fallback wake");
const pi = {
  on(event, handler) {
    if (event === "session_shutdown") sessionShutdown = handler;
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
      ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
      : 0;
    successorPidAtPrompt = readFileSync(process.env.FM_UNRETIRED_FILE, "utf8").trim();
    successorAliveAtPrompt = pidAlive(successorPidAtPrompt);
    fallbackDelivered.signal();
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-unretired-successor", {}, undefined, undefined, {});
// Each of these was a 5s poll for a file the successor writes. The successor
// now announces the same four points directly, so the driver reads a fact
// rather than sampling for its side effect.
await bus.reached("successor-startup");
if (!fireReadinessTimeout) throw new Error("successor readiness timeout was not captured");
writeFileSync(process.env.FM_ACTIVATE_FILE, "activate\n");
const successorPid = await bus.reached("successor-unretired");
if (readFileSync(process.env.FM_UNRETIRED_FILE, "utf8").trim() !== successorPid) {
  throw new Error(`successor announced ${successorPid} but recorded a different pid`);
}
if (!pidAlive(successorPid)) throw new Error(`successor ${successorPid} retired before the readiness deadline`);
fireReadinessTimeout();
await fallbackDelivered.reached;
await bus.reached("successor-retired");
const retiredPidAfterFallback = readFileSync(process.env.FM_RETIRED_FILE, "utf8").trim();
if (retiredPidAfterFallback !== successorPid) throw new Error(`post-fallback retirement evidence named ${retiredPidAfterFallback}, expected successor ${successorPid}`);
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`expected the initial arm and one established unretired successor, got: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (successorPidAtPrompt !== successorPid) throw new Error(`fallback observed successor ${successorPidAtPrompt}, expected ${successorPid}`);
if (!successorAliveAtPrompt || !pidAlive(successorPid)) throw new Error(`successor ${successorPid} was not genuinely unretired at fallback`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
sessionShutdown();
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// Process death cannot be announced by the dying process: the announcement
// necessarily precedes exit and can strand its writer if the bus closes after
// observing that earlier pid disappear. Observe the actual successor pid
// instead; this is the process-death check the shared helper preserves.
await waitForExit(successorPid, "successor exit");
bus.close();
EOF
  )
  status=$?
  [ -z "$out" ] || fail "Pi unretired-successor test printed output: $out"
  expect_code 0 "$status" "Pi must fall back without overlapping an unretired successor"
  pass "Pi unretired successor falls back without an overlapping retry"
}

test_pi_late_unretired_close_resumes_supervision() {
  local kind repo home plugin log startup activate ready retired release stop bus out status
  for kind in actionable non-actionable; do
    repo="$TMP_ROOT/pi-late-$kind-root"
    home="$TMP_ROOT/pi-late-$kind-home"
    log="$TMP_ROOT/pi-late-$kind.log"
    startup="$TMP_ROOT/pi-late-$kind.startup"
    activate="$TMP_ROOT/pi-late-$kind.activate"
    ready="$TMP_ROOT/pi-late-$kind.ready"
    retired="$TMP_ROOT/pi-late-$kind.retired"
    release="$TMP_ROOT/pi-late-$kind.release"
    stop="$TMP_ROOT/pi-late-$kind.stop"
    bus="$TMP_ROOT/pi-late-$kind.bus"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    fm_checkpoint_bus "$bus"
    install_pi_watch_extension_fixture "$repo"
    plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=0
  while IFS= read -r _; do count=$((count + 1)); done < "$FM_ARM_LOG"
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 1 ]; then
  printf 'waiting\n' > "${FM_STARTUP_FILE:?}"
  printf 'successor-startup %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
  while [ ! -e "$FM_ACTIVATE_FILE" ]; do sleep 0.02; done
  trap 'printf "%s\\n" "$$" > "${FM_UNRETIRED_RETIRE_FILE:?}"; printf "successor-retired %s\\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' TERM INT
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf '%s\n' "$$" > "${FM_UNRETIRED_READY_FILE:?}"
  printf 'successor-ready %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'printf "restored-exited %s\\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' EXIT
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STARTUP_FILE="$startup" FM_ACTIVATE_FILE="$activate" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_PI_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const readinessTimer = { unref() {} };
let fireReadinessTimeout = null;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_PI_ARM_READY_TIMEOUT_MS) && fireReadinessTimeout === null) {
    fireReadinessTimeout = () => callback(...args);
    return readinessTimer;
  }
  return nativeSetTimeout(callback, delay, ...args);
};
globalThis.clearTimeout = (timer) => {
  if (timer !== readinessTimer) nativeClearTimeout(timer);
};
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}
const { counter, openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
const prompts = [];
const wakes = counter("pi late-close wakes");
let successorPidAtFallback = "";
let successorAliveAtFallback = false;
let sessionShutdown = () => {};
const pi = {
  on(event, handler) {
    if (event === "session_shutdown") sessionShutdown = handler;
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(message);
    if (prompts.length === 1) {
      successorPidAtFallback = readFileSync(process.env.FM_UNRETIRED_READY_FILE, "utf8").trim();
      successorAliveAtFallback = pidAlive(successorPidAtFallback);
    }
    wakes.bump();
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-late-close", {}, undefined, undefined, {});
// The successor announces its startup gate, its readiness, and its retirement
// rather than leaving the driver to sample three marker files for 5s each.
await bus.reached("successor-startup");
if (!fireReadinessTimeout) throw new Error("successor readiness timeout was not captured");
writeFileSync(process.env.FM_ACTIVATE_FILE, "activate\n");
const successorPid = await bus.reached("successor-ready");
if (readFileSync(process.env.FM_UNRETIRED_READY_FILE, "utf8").trim() !== successorPid) {
  throw new Error(`successor announced ${successorPid} but recorded a different pid`);
}
if (!pidAlive(successorPid)) throw new Error(`successor ${successorPid} retired before the readiness deadline`);
fireReadinessTimeout();
await wakes.reached(1);
await bus.reached("successor-retired");
const retiredPidAfterFallback = readFileSync(process.env.FM_UNRETIRED_RETIRE_FILE, "utf8").trim();
if (retiredPidAfterFallback !== successorPid) throw new Error(`post-fallback retirement evidence named ${retiredPidAfterFallback}, expected successor ${successorPid}`);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (successorPidAtFallback !== successorPid) throw new Error(`fallback observed successor ${successorPidAtFallback}, expected ${successorPid}`);
if (!successorAliveAtFallback || !pidAlive(successorPid)) throw new Error(`successor ${successorPid} was not genuinely unretired at fallback`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// The restored third arm announces itself, and an actionable late close also
// has to reach a second wake. Both are awaited as events, so neither depends
// on 5s of polling being long enough for a late close to land.
await bus.reached("armed");
if (process.env.FM_LATE_KIND === "actionable") await wakes.reached(2);
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
sessionShutdown();
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
// Replaces an 80ms drain: the restored arm says when it is actually gone.
const exitedRestoredPid = await bus.reached("restored-exited");
await waitForExit(exitedRestoredPid, "restored arm exit");
bus.close();
EOF
)
    status=$?
    [ -z "$out" ] || fail "Pi late-$kind test printed output: $out"
    expect_code 0 "$status" "Pi late $kind close must remain supervised after fallback"
  done
  pass "Pi late unretired closes resume classified supervision"
}

test_pi_empty_close_retries_instead_of_disappearing() {
  local repo home plugin log stop bus out status
  repo="$TMP_ROOT/pi-empty-close-root"
  home="$TMP_ROOT/pi-empty-close-home"
  log="$TMP_ROOT/pi-empty-close.log"
  stop="$TMP_ROOT/pi-empty-close.stop"
  bus="$TMP_ROOT/pi-empty-close.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
let prompts = 0;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {
    prompts += 1;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-empty", {}, undefined, undefined, {});
// Each arm invocation announces its own logged row, so the retry is observed
// as two announcements rather than as a row count that has to be sampled
// often enough to catch.
await bus.reached("armed");
await bus.reached("armed");
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
process.exit(0);
EOF
  )
  status=$?
  expect_code 0 "$status" "Pi clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "Pi empty-close retry test printed output: $out"
  pass "Pi clean empty close triggers a bounded continuity retry"
}

test_pi_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/pi-established-empty-close-root"
  home="$TMP_ROOT/pi-established-empty-close-home"
  log="$TMP_ROOT/pi-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
let tool = null;
let prompt = "";
const exhaustionSurfaced = latch("pi retry-limit failure wake");
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    exhaustionSurfaced.signal();
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
// Retry exhaustion is reported through this stub, so the stub is the
// checkpoint for the whole retry sequence that precedes it.
await exhaustionSurfaced.reached;
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "Pi established-empty-close retry test printed output: $out"
  pass "Pi established clean closes stop at the configured retry limit"
}

test_pi_actionable_close_rechecks_session_lock() {
  local repo home plugin log release out status
  repo="$TMP_ROOT/pi-close-lock-root"
  home="$TMP_ROOT/pi-close-lock-home"
  log="$TMP_ROOT/pi-close-lock.log"
  release="$TMP_ROOT/pi-close-lock.release"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
let tool = null;
let prompt = "";
const wakeDelivered = latch("pi lock-loss wake");
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
    wakeDelivered.signal();
  },
};
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-lock-close", {}, undefined, undefined, {});
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  // Waiting on the first wake rather than on a wake whose text already
  // matches: the close handler must report lock loss and nothing else, so an
  // unexpected first message should fail here instead of being polled past.
  await wakeDelivered.reached;
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
}
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "Pi close handler must verify session-lock ownership before successor launch: $out"
  [ -z "$out" ] || fail "Pi close lock test printed output: $out"
  pass "Pi close handler verifies session-lock ownership before successor launch"
}

test_pi_arm_distinguishes_session_lock_ownership() {
  local repo home plugin log bus out status
  repo="$TMP_ROOT/pi-lock-ownership-root"
  home="$TMP_ROOT/pi-lock-ownership-home"
  log="$TMP_ROOT/pi-lock-ownership.log"
  bus="$TMP_ROOT/pi-lock-ownership.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { existsSync, unlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");

const lock = `${process.env.FM_HOME}/state/.lock`;
const callArm = () => tool.execute("tool-call-lock", {}, undefined, undefined, {});
const assertMissingLock = (result, label) => {
  if (result.details?.ok !== false) throw new Error(`${label} unexpectedly armed: ${JSON.stringify(result.details)}`);
  if (!result.details.message.includes("no live session holds the lock")) {
    throw new Error(`${label} missing no-live-session guidance: ${result.details.message}`);
  }
  if (!result.details.message.includes("bin/fm-session-start.sh") || !result.details.message.includes("re-arm")) {
    throw new Error(`${label} missing reclaim and re-arm guidance: ${result.details.message}`);
  }
  if (result.details.message.includes("held by another firstmate session")) {
    throw new Error(`${label} was misreported as a live other holder: ${result.details.message}`);
  }
};

if (existsSync(lock)) unlinkSync(lock);
assertMissingLock(await callArm(), "absent lock");
writeFileSync(lock, "999999\n");
assertMissingLock(await callArm(), "dead lock holder");

const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  const liveOther = await callArm();
  if (liveOther.details?.ok !== false) throw new Error(`live other holder unexpectedly armed: ${JSON.stringify(liveOther.details)}`);
  if (liveOther.details.message !== "watcher: read-only - session lock is held by another firstmate session") {
    throw new Error(`unexpected live-other response: ${liveOther.details.message}`);
  }
} finally {
  other.kill("SIGTERM");
}

if (existsSync(process.env.FM_ARM_LOG)) throw new Error("watcher arm ran without lock ownership");
writeFileSync(lock, `${process.pid}\n`);
const owned = await callArm();
if (owned.details?.ok !== true || !owned.details.message.includes("started Pi extension arm child")) {
  throw new Error(`owned lock did not arm: ${JSON.stringify(owned.details)}`);
}
// The arm child announces itself after writing its row, which is what "the
// watcher arm ran" actually means here.
await bus.reached("armed");
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("owned lock did not run the watcher arm");
bus.close();
EOF
)
  status=$?
  expect_code 0 "$status" "Pi watcher arm must distinguish owned, live-other, and missing or dead session locks"
  [ -z "$out" ] || fail "Pi lock-ownership arm test printed output: $out"
  pass "Pi watcher arm distinguishes all session lock ownership states"
}

test_pi_session_transition_generation_owner() {
  local repo home plugin child_pid_file arm_log bus out status
  repo="$TMP_ROOT/pi-session-transition-root"
  home="$TMP_ROOT/pi-session-transition-home"
  child_pid_file="$TMP_ROOT/pi-session-transition-child.pid"
  arm_log="$TMP_ROOT/pi-session-transition-arm.log"
  bus="$TMP_ROOT/pi-session-transition.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: started pid=%s\n' "$$"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf 'arm pid=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
trap 'exit 0' TERM INT
while :; do sleep 0.2; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CHILD_PID_FILE="$child_pid_file" FM_ARM_LOG="$arm_log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_pi") tool = candidate;
    },
    sendUserMessage: async () => {},
    events: { on() {} },
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function liveArmPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split(/\n/)
    .filter(Boolean)
    .map((line) => {
      const match = /pid=(\d+)/.exec(line);
      return match ? match[1] : "";
    })
    .filter(Boolean)
    .filter(pidAlive);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const startup = makePi();
mod.default(startup.pi);
await startup.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, {});
const first = await startup.getTool().execute("startup", {}, undefined, undefined, {});
if (!first.details?.ok || !String(first.details.message).includes("started Pi extension arm child")) {
  throw new Error(`startup arm failed: ${JSON.stringify(first.details)}`);
}
// Each arm child announces itself after both its pid file and its arm-log row
// are written, so the announcement is a stronger fact than the pid file merely
// existing - the old poll could observe the file before the row it is later
// counted by had landed.
const startupChild = await bus.reached("armed");
if (!pidAlive(startupChild)) throw new Error("startup child was not alive");
const staleTool = startup.getTool();

async function replaceSession(previous, reason) {
  const previousChild = existsSync(process.env.FM_CHILD_PID_FILE)
    ? readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim()
    : "";
  await previous.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason }, {});
  if (previousChild) {
    await waitForExit(previousChild, `${reason} previous child exit`);
  }
  const next = makePi();
  mod.default(next.pi);
  await next.handlers.get("session_start")?.({
    type: "session_start",
    reason,
    previousSessionFile: `/tmp/previous-${reason}.jsonl`,
  }, {});
  const armed = await next.getTool().execute(`arm-${reason}`, {}, undefined, undefined, {});
  if (!armed.details?.ok) {
    throw new Error(`${reason} replacement arm failed: ${JSON.stringify(armed.details)}`);
  }
  if (String(armed.details.message).includes("shutting down")) {
    throw new Error(`${reason} replacement still refused with shutting-down latch`);
  }
  const replacementChild = await bus.reached("armed");
  if (replacementChild === previousChild) {
    throw new Error(`${reason} replacement reused the previous child ${replacementChild}`);
  }
  if (!pidAlive(replacementChild)) throw new Error(`${reason} replacement child ${replacementChild} was not alive`);
  const live = liveArmPids();
  if (live.length !== 1) {
    throw new Error(`${reason} expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
  }
  return next;
}

let current = await replaceSession(startup, "new");
current = await replaceSession(current, "resume");
current = await replaceSession(current, "fork");

// Same bound instance: ordinary shutdown then session_start without a fresh factory.
const sameInstanceChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "new" }, {});
await current.handlers.get("session_start")?.({ type: "session_start", reason: "new" }, {});
const sameInstanceArm = await current.getTool().execute("same-instance", {}, undefined, undefined, {});
if (!sameInstanceArm.details?.ok || String(sameInstanceArm.details.message).includes("shutting down")) {
  throw new Error(`same-instance replacement arm failed: ${JSON.stringify(sameInstanceArm.details)}`);
}
const sameInstanceReplacement = await bus.reached("armed");
if (sameInstanceReplacement === sameInstanceChild) {
  throw new Error("same-instance replacement reused the previous child");
}
if (!pidAlive(sameInstanceReplacement)) throw new Error("same-instance replacement child was not alive");
await waitForExit(sameInstanceChild, "same-instance previous child exit");
if (liveArmPids().length !== 1) {
  throw new Error(`same-instance expected one live arm child, got ${liveArmPids().join(",")}`);
}

// Stale prior-generation callback must not stop, rearm, or clear the active generation.
const activeChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
const stale = await staleTool.execute("stale-prior-generation", {}, undefined, undefined, {});
if (stale.details?.ok !== false || !String(stale.details.message).includes("shutting down")) {
  throw new Error(`stale prior generation did not refuse: ${JSON.stringify(stale.details)}`);
}
if (!pidAlive(activeChild)) throw new Error("active generation child died after stale callback");
if (pidAlive(startupChild)) throw new Error("startup generation child was resurrected");
if (liveArmPids().length !== 1 || liveArmPids()[0] !== activeChild) {
  throw new Error(`stale callback mutated live arm set: ${liveArmPids().join(",")}`);
}
const redundant = await current.getTool().execute("redundant", {}, undefined, undefined, {});
if (!redundant.details?.ok || !String(redundant.details.message).includes("unchanged")) {
  throw new Error(`active generation lost single-flight ownership: ${JSON.stringify(redundant.details)}`);
}

// Repeated transitions keep exactly one live cycle and never revive the refusal.
for (const reason of ["resume", "fork", "new", "resume"]) {
  current = await replaceSession(current, reason);
}

// Real terminal shutdown still blocks late rearming.
const finalChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
await current.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, {});
await waitForExit(finalChild, "terminal shutdown child exit");
const quitArm = await current.getTool().execute("after-quit", {}, undefined, undefined, {});
if (quitArm.details?.ok !== false || quitArm.details.message !== "watcher: not armed - Pi session is shutting down") {
  throw new Error(`terminal quit must keep the shutting-down refusal: ${JSON.stringify(quitArm.details)}`);
}
if (liveArmPids().length !== 0) {
  throw new Error(`terminal quit left live arm children: ${liveArmPids().join(",")}`);
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi session transitions must rearm through an explicit generation owner"
  [ -z "$out" ] || fail "Pi session-transition generation owner test printed output: $out"
  pass "Pi session transitions use a generation owner across /new /resume /fork, stale callbacks, and quit"
}

test_pi_process_exit_cleanup_listener_lifecycle() {
  local repo home plugin out status
  repo="$TMP_ROOT/pi-exit-listener-root"
  home="$TMP_ROOT/pi-exit-listener-home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";

const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool() {},
  sendUserMessage: async () => {},
};
const before = process.listenerCount("exit");
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("Pi extension did not install exactly one process-exit fallback");
}
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("session_shutdown removed the process-lifetime exit fallback");
}
await handlers.get("session_start")?.({ type: "session_start" }, {});
if (process.listenerCount("exit") !== before + 1) {
  throw new Error("replacement activation duplicated the process-exit fallback");
}
EOF
)
  status=$?
  expect_code 0 "$status" "Pi cleanup fallback listener must remain singular across session replacement"
  [ -z "$out" ] || fail "Pi listener-lifecycle test printed output: $out"
  pass "Pi process-exit cleanup listener remains singular across session replacement"
}

test_pi_process_exit_cleanup_stops_arm_child() {
  local repo home plugin cleanup_log pid_file bus out status pid i
  repo="$TMP_ROOT/pi-process-exit-root"
  home="$TMP_ROOT/pi-process-exit-home"
  cleanup_log="$TMP_ROOT/pi-process-exit-cleaned"
  pid_file="$TMP_ROOT/pi-process-exit-child.pid"
  bus="$TMP_ROOT/pi-process-exit.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
trap 'printf "%s\n" "$$" >> "$FM_CLEANUP_LOG"; exit 0' TERM
printf '%s\n' "$$" > "$FM_CHILD_PID_FILE"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while :; do sleep 1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_CLEANUP_LOG="$cleanup_log" FM_CHILD_PID_FILE="$pid_file" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
let tool = null;
const handlers = new Map();
const pi = {
  on(event, handler) {
    handlers.set(event, handler);
  },
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-exit", {}, undefined, undefined, {});
// The child announces its own pid once the pid file is written. The old poll
// waited for that file to exist and then read it, which can observe the file
// between the shell creating it and the write landing.
const firstChild = await bus.reached("armed");
await handlers.get("session_shutdown")?.({ type: "session_shutdown" }, {});
await handlers.get("session_start")?.({ type: "session_start" }, {});
await tool.execute("tool-call-replacement", {}, undefined, undefined, {});
const replacementChild = await bus.reached("armed");
if (replacementChild === firstChild) throw new Error("replacement arm child did not start");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "Pi process exit must run the watcher cleanup fallback"
  [ -z "$out" ] || fail "Pi process-exit cleanup test printed output: $out"
  pid=$(cat "$pid_file")
  # Deliberately still a bounded poll. The driver has exited by now, so
  # nothing holds the checkpoint bus open and the arm child's TERM handler
  # would block forever trying to announce. A checkpoint here would also be
  # delivered by the very TERM this assertion exists to prove was sent, so a
  # regression would stall with no message instead of reporting the miss.
  i=0
  while [ "$i" -lt 250 ] && ! grep -qx "$pid" "$cleanup_log" 2>/dev/null; do
    sleep 0.02
    i=$((i + 1))
  done
  grep -qx "$pid" "$cleanup_log" 2>/dev/null || fail "Pi process-exit fallback did not deliver TERM to the replacement arm child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    fail "Pi arm child $pid survived process-exit cleanup"
  fi
  pass "Pi process-exit cleanup stops the attached arm child"
}

test_opencode_plugin_package_boundary_is_explicit_esm() {
  local fixture plugin out status
  fixture="$TMP_ROOT/opencode-esm-boundary/.opencode"
  plugin="$fixture/plugins/fm-primary-watch-arm.js"
  mkdir -p "$fixture/plugins/lib"
  printf '%s\n' '{"dependencies":{}}' > "$fixture/package.json"
  cp "$ROOT/.opencode/plugins/package.json" "$fixture/plugins/package.json"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$plugin"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$fixture/plugins/lib/fm-operational-input.js"
  out=$(PLUGIN="$plugin" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
await import(pathToFileURL(process.env.PLUGIN).href);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode plugin must import beneath an explicit ESM package boundary"
  [ -z "$out" ] || fail "OpenCode ESM boundary import printed output: $out"
  pass "OpenCode plugins have an explicit ESM boundary even under a typeless parent package"
}

test_opencode_primary_watch_plugin_uses_effective_state_home() {
  local plugin repo home log bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-state-root"
  home="$TMP_ROOT/opencode-effective-state-home"
  log="$TMP_ROOT/opencode-effective-state.log"
  bus="$TMP_ROOT/opencode-effective-state.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'home=%s root=%s\n' "${FM_HOME:-}" "${FM_ROOT_OVERRIDE:-}" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { existsSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The arm child announces itself once its row is written, so the driver reads
// a complete row rather than sampling for the file to appear.
await bus.reached("armed");
bus.close();
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
const expectedRoot = realpathSync(process.env.WORKTREE);
if (!text.includes(`home=${process.env.FM_HOME}`) || !text.includes(`root=${expectedRoot}`)) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must use FM_HOME state outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-state test printed output: $out"
  pass "OpenCode watcher plugin uses the effective FM_HOME state"
}

test_opencode_primary_watch_plugin_sources_effective_config() {
  local plugin repo home log bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-effective-config-root"
  home="$TMP_ROOT/opencode-effective-config-home"
  log="$TMP_ROOT/opencode-effective-config.log"
  bus="$TMP_ROOT/opencode-effective-config.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'export FM_POLL=7\n' > "$home/config/x-mode.env"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'poll=%s\n' "${FM_POLL:-missing}" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The arm child announces its written row, so the config value read below is
// never read out of a row that is still being written.
await bus.reached("armed");
bus.close();
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
const text = readFileSync(process.env.FM_ARM_LOG, "utf8");
if (!text.includes("poll=7")) {
  console.error(text);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must source FM_HOME config outside the repo root"
  [ -z "$out" ] || fail "OpenCode effective-config test printed output: $out"
  pass "OpenCode watcher plugin sources the effective config"
}

test_opencode_primary_watch_plugin_requires_session_lock() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-lock-root"
  home="$TMP_ROOT/opencode-lock-home"
  log="$TMP_ROOT/opencode-lock.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, "999999\n");
const readOnlyStatus = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (readOnlyStatus !== "read-only") {
  console.error(`watch arm returned ${readOnlyStatus} without owning the session lock`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm ran without owning the session lock");
  process.exit(1);
}
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const ownedStatus = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
if (ownedStatus !== "external") {
  console.error(`watch arm returned ${ownedStatus} with session lock ownership`);
  process.exit(1);
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run after the session lock matched");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must arm only when this session owns the fleet lock"
  [ -z "$out" ] || fail "OpenCode session-lock test printed output: $out"
  pass "OpenCode watcher plugin requires session lock ownership"
}

test_opencode_watch_arm_coordinator_respects_primary_scope() {
  local plugin base repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  base="$TMP_ROOT/opencode-coordinator-base"
  repo="$TMP_ROOT/opencode-coordinator-wt"
  home="$TMP_ROOT/opencode-coordinator-home"
  log="$TMP_ROOT/opencode-coordinator.log"
  fm_git_worktree "$base" "$repo" fm/opencode-coordinator
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("session-test", client);
// Left as a duration on purpose: the claim is that a linked worktree arms
// NOTHING, so there is no checkpoint to wait on - only a window in which an
// arm that should not exist would have had time to write its row.
await new Promise((resolve) => setTimeout(resolve, 120));
if (status !== "not-primary") {
  console.error(`expected not-primary, got ${status}`);
  process.exit(1);
}
if (existsSync(process.env.FM_ARM_LOG)) {
  console.error("coordinator armed from a linked worktree");
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch coordinator must keep primary scope checks in the shared arm path"
  [ -z "$out" ] || fail "OpenCode coordinator-scope test printed output: $out"
  pass "OpenCode watcher coordinator respects primary scope"
}

test_opencode_primary_watch_plugin_rearms_after_wake() {
  local plugin repo home log stop bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-rearm-root"
  home="$TMP_ROOT/opencode-rearm-home"
  log="$TMP_ROOT/opencode-rearm.log"
  stop="$TMP_ROOT/opencode-rearm.stop"
  bus="$TMP_ROOT/opencode-rearm.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  printf 'confirmed %s\n' "$2" > "${FM_CHECKPOINT_BUS:?}"
  exit 0
fi
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-generation\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch, openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
let rowsAtPrompt = 0;
const promptBegan = latch("opencode wake prompt began");
let releasePrompt = () => {};
const promptBlocked = new Promise((resolve) => {
  releasePrompt = resolve;
});
const client = {
  session: {
    promptAsync: async () => {
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      prompts += 1;
      promptBegan.signal();
      await promptBlocked;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const event = { event: { type: "session.idle", properties: { sessionID: "session-test" } } };
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event(event);
// The wake prompt entering the stub in this driver is the checkpoint. The
// successor arm row is written before the prompt begins, and rowsAtPrompt
// below is what actually proves that ordering.
await promptBegan.reached;
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`expected one successor arm, got ${rows.length}: ${rows.join(" | ")}`);
if (prompts !== 1) throw new Error(`expected one blocked wake prompt, got ${prompts}`);
if (rowsAtPrompt !== 2) throw new Error(`wake prompt began before successor establishment (${rowsAtPrompt} arm rows)`);
if (!/predecessor=[0-9]+/.test(rows[1])) throw new Error(`successor did not receive predecessor identity: ${rows[1]}`);
// Left as a duration on purpose: this asserts that delivery is NOT confirmed
// while the prompt is still outstanding, and an absence needs a window.
await new Promise((resolve) => setTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 2) throw new Error(`delivery was confirmed before the prompt succeeded: ${stableRows.join(" | ")}`);
releasePrompt();
// The confirming arm invocation announces itself instead of the driver
// re-reading the log for a second hoping the row shows up.
await bus.reached("confirmed");
const confirmedRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (confirmedRows.filter((row) => row.startsWith("confirmed ")).length !== 1) {
  throw new Error(`successful prompt delivery was not confirmed exactly once: ${confirmedRows.join(" | ")}`);
}
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
bus.close();
EOF
  )
  status=$?
  [ "$status" -eq 0 ] || fail "OpenCode watch plugin must start one successor before wake prompt delivery settles: $out"
  [ -z "$out" ] || fail "OpenCode rearm test printed output: $out"
  pass "OpenCode watcher plugin starts one successor before wake prompt delivery settles"
}

test_opencode_pre_ready_actionable_close_preserves_its_successor() {
  local plugin repo home log release retired stop bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-pre-ready-actionable-root"
  home="$TMP_ROOT/opencode-pre-ready-actionable-home"
  log="$TMP_ROOT/opencode-pre-ready-actionable.log"
  release="$TMP_ROOT/opencode-pre-ready-actionable.release"
  retired="$TMP_ROOT/opencode-pre-ready-actionable.retired"
  stop="$TMP_ROOT/opencode-pre-ready-actionable.stop"
  bus="$TMP_ROOT/opencode-pre-ready-actionable.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'signal: pre-ready successor wake\n'
  trap 'printf "retired\\n" > "${FM_PRE_READY_RETIRED_FILE:?}"; exit 0' TERM INT
  while [ ! -e "$FM_PRE_READY_RELEASE_FILE" ]; do sleep 0.02; done
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRE_READY_RELEASE_FILE="$release" FM_PRE_READY_RETIRED_FILE="$retired" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { counter, openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const wakes = counter("opencode pre-ready wakes");
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
      wakes.bump();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Two arms announce themselves and one wake is delivered. Both are awaited as
// events rather than sampled out of a growing log for up to five seconds.
await bus.reached("armed");
await bus.reached("armed");
await wakes.reached(1);
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`pre-ready successor was replaced before its close: ${rows.join(" | ")}`);
if (!prompts.some((message) => message.includes("original wake"))) throw new Error(`original actionable wake was not delivered: ${prompts.join(" | ")}`);
// Left as a duration on purpose: the claim is that the pre-ready successor is
// NOT retired before its own close, and an absence needs a window.
await new Promise((resolve) => setTimeout(resolve, 150));
if (existsSync(process.env.FM_PRE_READY_RETIRED_FILE)) throw new Error("pre-ready actionable successor was retired before its close");
writeFileSync(process.env.FM_PRE_READY_RELEASE_FILE, "release\n");
await bus.reached("armed");
await wakes.reached(2);
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 3) throw new Error(`pre-ready close did not create exactly one successor: ${stableRows.join(" | ")}`);
if (!prompts.some((message) => message.includes("pre-ready successor wake"))) throw new Error(`pre-ready actionable wake was not delivered: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
bus.close();
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retire the pre-ready arm, not its actionable successor"
  [ -z "$out" ] || fail "OpenCode pre-ready actionable test printed output: $out"
  pass "OpenCode pre-ready actionable close preserves its successor"
}

test_opencode_undetermined_primacy_probe_retries_instead_of_abandoning() {
  local plugin repo home log shim marker stop out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-primacy-undetermined-root"
  home="$TMP_ROOT/opencode-primacy-undetermined-home"
  log="$TMP_ROOT/opencode-primacy-undetermined.log"
  shim="$TMP_ROOT/opencode-primacy-undetermined-shim"
  marker="$shim/fired"
  stop="$TMP_ROOT/opencode-primacy-undetermined.stop"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$shim"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # A real git that fails --git-dir exactly once, and only once the first arm
  # has run, so the failure lands on the restoration's primacy probe rather
  # than on the initial arm. A fork-pressured box fails any spawn this way, and
  # the coordinator must not read "could not determine primacy" as the
  # permanent "this is not a primary checkout".
  cat > "$shim/git" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_ARM_LOG:-}" ] && [ -e "\$FM_ARM_LOG" ] && [ ! -e "$marker" ]; then
  case " \$* " in
    *" --git-dir "*)
      : > "$marker"
      echo 'fatal: cannot exec: Resource temporarily unavailable' >&2
      exit 128
      ;;
  esac
fi
exec $(command -v git) "\$@"
SH
  chmod +x "$shim/git"
  out=$(PATH="$shim:$PATH" PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_PRIMACY_FAULT_MARKER="$marker" FM_STOP_FILE="$stop" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { counter } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const wakes = counter("opencode primacy-probe wakes");
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
      wakes.bump();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const rows = () => (existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : []);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Wait on the completed transition, not on the arm row alone: the successor
// row lands before restoration returns, so gating on the row count would race
// the delivery that follows it.
//
// The first delivered wake is that completion, and it is deliberately the
// only checkpoint here. Both outcomes reach it - a healthy retry delivers the
// original wake, and the regression this test exists for delivers a
// restoration-failure wake instead - so the assertions below still fire on the
// defect rather than the driver stalling on a successor a broken coordinator
// would never start. That distinction is the whole point of this test: the
// abandonment bug it caught was blamed on a deadline, and a checkpoint on the
// successor alone would have hidden it.
await wakes.reached(1);
if (!existsSync(process.env.FM_PRIMACY_FAULT_MARKER)) {
  throw new Error("the transient primacy-probe failure never fired, so this case proved nothing");
}
const armRows = rows();
if (armRows.length !== 2) {
  throw new Error(`restoration abandoned its successor after an undetermined primacy probe: ${armRows.join(" | ")}`);
}
if (!prompts.some((message) => message.includes("signal: original wake"))) {
  throw new Error(`original wake was lost: ${prompts.join(" | ")}`);
}
const abandoned = prompts.find((message) => message.includes("could not verify a ready successor watcher"));
if (abandoned) throw new Error(`restoration reported failure instead of spending its retries: ${abandoned}`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode must retry a primacy probe it could not complete, not abandon continuity"
  [ -z "$out" ] || fail "OpenCode undetermined-primacy test printed output: $out"
  pass "OpenCode undetermined primacy probe retries instead of abandoning continuity"
}

test_opencode_hung_successor_falls_back_to_typed_wake() {
  local plugin repo home log bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-hung-successor-root"
  home="$TMP_ROOT/opencode-hung-successor-home"
  log="$TMP_ROOT/opencode-hung-successor.log"
  bus="$TMP_ROOT/opencode-hung-successor.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
trap 'exit 0' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { counter, latch, openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const readinessTimer = { unref() {} };
const fireReadinessTimeouts = [];
// Capturing a readiness timeout is an in-process event, so it is counted and
// awaited rather than polled for through a growing array.
const readinessCaptured = counter("opencode captured readiness timeouts");
let readinessAttempts = 0;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS)) {
    readinessAttempts += 1;
    if (readinessAttempts >= 2) {
      fireReadinessTimeouts.push(() => callback(...args));
      readinessCaptured.bump();
      return readinessTimer;
    }
  }
  return nativeSetTimeout(callback, delay, ...args);
};
globalThis.clearTimeout = (timer) => {
  if (timer !== readinessTimer) nativeClearTimeout(timer);
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
const fallbackDelivered = latch("opencode hung-successor fallback wake");
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      fallbackDelivered.signal();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The original arm, then one announcement per successor. Each successor is
// stepped through its own two checkpoints - its arm row and its captured
// readiness timeout - instead of both being sampled together for 5s.
await bus.reached("armed");
for (let successor = 0; successor < 3; successor += 1) {
  await bus.reached("armed");
  await readinessCaptured.reached(successor + 1);
  fireReadinessTimeouts[successor]();
}
await fallbackDelivered.reached;
bus.close();
const finalRows = rows();
if (finalRows.length !== 4) throw new Error(`expected one successor plus two retries, got ${finalRows.length}: ${finalRows.join(" | ")}`);
if (rowsAtPrompt !== 4) throw new Error(`wake arrived before restoration exhausted (${rowsAtPrompt} arm rows)`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("could not restore watcher continuity after 2 retries")) throw new Error(`missing typed restoration failure: ${prompt}`);
// Left as a duration on purpose: single-flight recovery is a claim that no
// further arm is launched, which an absence-window is the only way to check.
await new Promise((resolve) => nativeSetTimeout(resolve, 100));
const stableRows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (stableRows.length !== 4) throw new Error(`single-flight recovery launched ${stableRows.length} arms`);
EOF
)
  status=$?
  [ -z "$out" ] || fail "OpenCode hung-successor test printed output: $out"
  expect_code 0 "$status" "OpenCode must deliver the actionable wake after bounded hung-successor recovery"
  pass "OpenCode hung successor falls back to one typed actionable wake"
}

test_opencode_unretired_successor_falls_back_without_retry() {
  local plugin repo home log startup activate unretired retired release bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-unretired-successor-root"
  home="$TMP_ROOT/opencode-unretired-successor-home"
  log="$TMP_ROOT/opencode-unretired-successor.log"
  startup="$TMP_ROOT/opencode-unretired-successor.startup"
  activate="$TMP_ROOT/opencode-unretired-successor.activate"
  unretired="$TMP_ROOT/opencode-unretired-successor.unretired"
  retired="$TMP_ROOT/opencode-unretired-successor.retired"
  release="$TMP_ROOT/opencode-unretired-successor.release"
  bus="$TMP_ROOT/opencode-unretired-successor.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: synthetic wake\n'
  exit 0
fi
printf 'waiting\n' > "${FM_STARTUP_FILE:?}"
printf 'successor-startup %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while [ ! -e "$FM_ACTIVATE_FILE" ]; do sleep 0.02; done
trap 'printf "%s\n" "$$" > "${FM_RETIRED_FILE:?}"; printf "successor-retired %s\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' TERM INT
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf '%s\n' "$$" > "${FM_UNRETIRED_FILE:?}"
printf 'successor-unretired %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.1; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STARTUP_FILE="$startup" FM_ACTIVATE_FILE="$activate" FM_UNRETIRED_FILE="$unretired" FM_RETIRED_FILE="$retired" FM_RELEASE_FILE="$release" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const readinessTimer = { unref() {} };
let readinessAttempts = 0;
let fireReadinessTimeout = null;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS)) {
    readinessAttempts += 1;
    if (readinessAttempts === 2) {
      fireReadinessTimeout = () => callback(...args);
      return readinessTimer;
    }
  }
  return nativeSetTimeout(callback, delay, ...args);
};
globalThis.clearTimeout = (timer) => {
  if (timer !== readinessTimer) nativeClearTimeout(timer);
};
const { latch, openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
let rowsAtPrompt = 0;
let successorPidAtPrompt = "";
let successorAliveAtPrompt = false;
const fallbackDelivered = latch("opencode unretired-successor fallback wake");
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      rowsAtPrompt = existsSync(process.env.FM_ARM_LOG)
        ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length
        : 0;
      successorPidAtPrompt = readFileSync(process.env.FM_UNRETIRED_FILE, "utf8").trim();
      successorAliveAtPrompt = pidAlive(successorPidAtPrompt);
      fallbackDelivered.signal();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Each of these was a 5s poll for a marker file, and two of them then read
// that file for a pid. existsSync can see a file the shell has created by
// redirection but not yet written, which is how this test produced an empty
// "post-fallback retirement evidence named" during this work. Announcing
// after the write closes that window.
await bus.reached("successor-startup");
if (!fireReadinessTimeout) throw new Error("successor readiness timeout was not captured");
writeFileSync(process.env.FM_ACTIVATE_FILE, "activate\n");
const successorPid = await bus.reached("successor-unretired");
if (readFileSync(process.env.FM_UNRETIRED_FILE, "utf8").trim() !== successorPid) {
  throw new Error(`successor announced ${successorPid} but recorded a different pid`);
}
if (!pidAlive(successorPid)) throw new Error(`successor ${successorPid} retired before the readiness deadline`);
fireReadinessTimeout();
await fallbackDelivered.reached;
await bus.reached("successor-retired");
const retiredPidAfterFallback = readFileSync(process.env.FM_RETIRED_FILE, "utf8").trim();
if (retiredPidAfterFallback !== successorPid) throw new Error(`post-fallback retirement evidence named ${retiredPidAfterFallback}, expected successor ${successorPid}`);
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 2) throw new Error(`expected the initial arm and one established unretired successor, got: ${rows.join(" | ")}`);
if (rowsAtPrompt !== 2) throw new Error(`wake arrived after an overlapping retry (${rowsAtPrompt} arm rows)`);
if (successorPidAtPrompt !== successorPid) throw new Error(`fallback observed successor ${successorPidAtPrompt}, expected ${successorPid}`);
if (!successorAliveAtPrompt || !pidAlive(successorPid)) throw new Error(`successor ${successorPid} was not genuinely unretired at fallback`);
if (!prompt.includes("signal: synthetic wake")) throw new Error(`original wake was lost: ${prompt}`);
if (!prompt.includes("unready successor arm did not exit within 20ms")) throw new Error(`missing unretired-arm failure: ${prompt}`);
rmSync(`${process.env.FM_HOME}/state/.lock`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// Process death cannot be announced by the dying process. Observe the actual
// successor pid with the shared process-death check instead.
await waitForExit(successorPid, "successor exit");
bus.close();
EOF
)
  status=$?
  [ -z "$out" ] || fail "OpenCode unretired-successor test printed output: $out"
  expect_code 0 "$status" "OpenCode must fall back without overlapping an unretired successor"
  pass "OpenCode unretired successor falls back without an overlapping retry"
}

test_opencode_late_unretired_close_resumes_supervision() {
  local kind plugin repo home log startup activate ready retired release stop bus out status
  for kind in actionable non-actionable; do
    plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
    repo="$TMP_ROOT/opencode-late-$kind-root"
    home="$TMP_ROOT/opencode-late-$kind-home"
    log="$TMP_ROOT/opencode-late-$kind.log"
    startup="$TMP_ROOT/opencode-late-$kind.startup"
    activate="$TMP_ROOT/opencode-late-$kind.activate"
    ready="$TMP_ROOT/opencode-late-$kind.ready"
    retired="$TMP_ROOT/opencode-late-$kind.retired"
    release="$TMP_ROOT/opencode-late-$kind.release"
    stop="$TMP_ROOT/opencode-late-$kind.stop"
    bus="$TMP_ROOT/opencode-late-$kind.bus"
    mkdir -p "$repo/bin" "$home/state" "$home/config"
    fm_checkpoint_bus "$bus"
    git init -q "$repo"
    : > "$repo/AGENTS.md"
    : > "$home/state/task.meta"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_ARM_LOG" ]; then
  count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
else
  count=0
fi
if [ "$count" -eq 0 ]; then
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: original wake\n'
  exit 0
fi
if [ "$count" -eq 1 ]; then
  printf 'waiting\n' > "${FM_STARTUP_FILE:?}"
  printf 'successor-startup %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
  while [ ! -e "$FM_ACTIVATE_FILE" ]; do sleep 0.02; done
  trap 'printf "%s\\n" "$$" > "${FM_UNRETIRED_RETIRE_FILE:?}"; printf "successor-retired %s\\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' TERM INT
  printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
  printf '%s\n' "$$" > "${FM_UNRETIRED_READY_FILE:?}"
  printf 'successor-ready %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
  while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
  [ "$FM_LATE_KIND" = actionable ] && printf 'signal: late wake\n'
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'printf "restored-exited %s\\n" "$$" > "${FM_CHECKPOINT_BUS:?}"' EXIT
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STARTUP_FILE="$startup" FM_ACTIVATE_FILE="$activate" FM_UNRETIRED_READY_FILE="$ready" FM_UNRETIRED_RETIRE_FILE="$retired" FM_RELEASE_FILE="$release" FM_STOP_FILE="$stop" FM_LATE_KIND="$kind" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_OPENCODE_ARM_READY_TIMEOUT_MS=250 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=20 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const readinessTimers = [];
globalThis.setTimeout = (callback, delay, ...args) => {
  if (delay === Number(process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS)) {
    const timer = { active: true, fire: () => callback(...args), unref() {} };
    readinessTimers.push(timer);
    return timer;
  }
  return nativeSetTimeout(callback, delay, ...args);
};
globalThis.clearTimeout = (timer) => {
  if (readinessTimers.includes(timer)) timer.active = false;
  else nativeClearTimeout(timer);
};
function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}
const { counter, openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const prompts = [];
const wakes = counter("opencode late-close wakes");
let successorPidAtFallback = "";
let successorAliveAtFallback = false;
const client = {
  session: {
    promptAsync: async (request) => {
      prompts.push(request.body.parts[0].text);
      if (prompts.length === 1) {
        successorPidAtFallback = readFileSync(process.env.FM_UNRETIRED_READY_FILE, "utf8").trim();
        successorAliveAtFallback = pidAlive(successorPidAtFallback);
      }
      wakes.bump();
    },
  },
};
const rows = () => existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The successor announces its startup gate, its readiness, and its retirement
// rather than leaving the driver to sample three marker files for 5s each.
await bus.reached("successor-startup");
writeFileSync(process.env.FM_ACTIVATE_FILE, "activate\n");
const successorPid = await bus.reached("successor-ready");
if (readFileSync(process.env.FM_UNRETIRED_READY_FILE, "utf8").trim() !== successorPid) {
  throw new Error(`successor announced ${successorPid} but recorded a different pid`);
}
const readinessTimer = readinessTimers.findLast((timer) => timer.active);
if (!readinessTimer) throw new Error("successor readiness timeout was not captured");
if (!pidAlive(successorPid)) throw new Error(`successor ${successorPid} retired before the readiness deadline`);
readinessTimer.fire();
await wakes.reached(1);
await bus.reached("successor-retired");
const retiredPidAfterFallback = readFileSync(process.env.FM_UNRETIRED_RETIRE_FILE, "utf8").trim();
if (retiredPidAfterFallback !== successorPid) throw new Error(`post-fallback retirement evidence named ${retiredPidAfterFallback}, expected successor ${successorPid}`);
if (rows().length !== 2) throw new Error(`unretired arm overlapped before fallback: ${rows().join(" | ")}`);
if (successorPidAtFallback !== successorPid) throw new Error(`fallback observed successor ${successorPidAtFallback}, expected ${successorPid}`);
if (!successorAliveAtFallback || !pidAlive(successorPid)) throw new Error(`successor ${successorPid} was not genuinely unretired at fallback`);
if (!prompts[0]?.includes("original wake")) throw new Error(`missing original fallback: ${prompts.join(" | ")}`);
writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
// The restored third arm announces itself, and an actionable late close also
// has to reach a second wake. Both are awaited as events, so neither depends
// on 5s of polling being long enough for a late close to land.
await bus.reached("armed");
if (process.env.FM_LATE_KIND === "actionable") await wakes.reached(2);
if (rows().length !== 3) throw new Error(`late close did not restore one successor: ${rows().join(" | ")}`);
if (process.env.FM_LATE_KIND === "actionable") {
  if (prompts.length !== 2 || !prompts[1].includes("late wake")) throw new Error(`late actionable close was not delivered: ${prompts.join(" | ")}`);
} else if (prompts.length !== 1) {
  throw new Error(`late non-actionable close sent an extra wake: ${prompts.join(" | ")}`);
}
rmSync(`${process.env.FM_HOME}/state/.lock`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
// Replaces an 80ms drain: the restored arm says when it is actually gone.
const exitedRestoredPid = await bus.reached("restored-exited");
await waitForExit(exitedRestoredPid, "restored arm exit");
bus.close();
EOF
)
    status=$?
    [ -z "$out" ] || fail "OpenCode late-$kind test printed output: $out"
    expect_code 0 "$status" "OpenCode late $kind close must remain supervised after fallback"
  done
  pass "OpenCode late unretired closes resume classified supervision"
}

test_opencode_empty_close_retries_instead_of_disappearing() {
  local plugin repo home log stop bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-empty-close-root"
  home="$TMP_ROOT/opencode-empty-close-home"
  log="$TMP_ROOT/opencode-empty-close.log"
  stop="$TMP_ROOT/opencode-empty-close.stop"
  bus="$TMP_ROOT/opencode-empty-close.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
count=$(wc -l < "$FM_ARM_LOG" | tr -d '[:space:]')
if [ "$count" -eq 1 ]; then exit 0; fi
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompts = 0;
const client = {
  session: {
    promptAsync: async () => {
      prompts += 1;
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Each arm invocation announces its own logged row, so the retry is observed
// as two announcements rather than as a row count sampled often enough to
// catch.
await bus.reached("armed");
await bus.reached("armed");
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 2) throw new Error(`clean empty close was ignored: ${rows.join(" | ")}`);
if (prompts !== 0) throw new Error(`restored transient close surfaced ${prompts} failure prompts`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
bus.close();
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode clean empty close must trigger a bounded continuity retry"
  [ -z "$out" ] || fail "OpenCode empty-close retry test printed output: $out"
  pass "OpenCode clean empty close triggers a bounded continuity retry"
}

test_opencode_established_empty_close_honors_retry_limit() {
  local plugin repo home log out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-established-empty-close-root"
  home="$TMP_ROOT/opencode-established-empty-close-home"
  log="$TMP_ROOT/opencode-established-empty-close.log"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const exhaustionSurfaced = latch("opencode retry-limit failure wake");
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      exhaustionSurfaced.signal();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// Retry exhaustion is reported through this stub, so the stub is the
// checkpoint for the whole retry sequence that precedes it.
await exhaustionSurfaced.reached;
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode established clean closes must honor the continuity retry limit"
  [ -z "$out" ] || fail "OpenCode established-empty-close retry test printed output: $out"
  pass "OpenCode established clean closes stop at the configured retry limit"
}

test_opencode_actionable_close_rechecks_session_lock() {
  local plugin repo home log release bus out status
  plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  repo="$TMP_ROOT/opencode-close-lock-root"
  home="$TMP_ROOT/opencode-close-lock-home"
  log="$TMP_ROOT/opencode-close-lock.log"
  release="$TMP_ROOT/opencode-close-lock.release"
  bus="$TMP_ROOT/opencode-close-lock.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
while [ ! -e "$FM_RELEASE_FILE" ]; do sleep 0.02; done
printf 'signal: lock handoff\n'
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_RELEASE_FILE="$release" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { latch, openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
let prompt = "";
const wakeDelivered = latch("opencode lock-loss wake");
const client = {
  session: {
    promptAsync: async (request) => {
      prompt += request.body.parts[0].text;
      wakeDelivered.signal();
    },
  },
};
const hooks = await mod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const lock = `${process.env.FM_HOME}/state/.lock`;
writeFileSync(lock, `${process.pid}\n`);
const eventPromise = hooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The arm child announces itself, so the lock is only stolen once the arm is
// genuinely running rather than once its log file happens to be visible.
await bus.reached("armed");
const other = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
try {
  writeFileSync(lock, `${other.pid}\n`);
  writeFileSync(process.env.FM_RELEASE_FILE, "release\n");
  await eventPromise;
  // Waiting on the first wake rather than on a wake whose text already
  // matches: the close handler must report lock loss and nothing else, so an
  // unexpected first message should fail here instead of being polled past.
  await wakeDelivered.reached;
  const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
  if (rows.length !== 1) throw new Error(`successor launched after lock loss: ${rows.join(" | ")}`);
  if (!prompt.includes("no longer owns the lock")) throw new Error(`missing lock-loss failure: ${prompt}`);
} finally {
  other.kill("SIGTERM");
  bus.close();
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode close handler must verify session-lock ownership before successor launch"
  [ -z "$out" ] || fail "OpenCode close lock test printed output: $out"
  pass "OpenCode close handler verifies session-lock ownership before successor launch"
}

test_opencode_watch_arm_coordinates_with_turnend_guard() {
  local arm_plugin guard_plugin repo home log guard_log bus out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-coordinate-root"
  home="$TMP_ROOT/opencode-coordinate-home"
  log="$TMP_ROOT/opencode-coordinate-arm.log"
  guard_log="$TMP_ROOT/opencode-coordinate-guard.log"
  bus="$TMP_ROOT/opencode-coordinate.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: started pid=1 (beacon fresh)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard should not run\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { existsSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The arm child announces itself, so "the guard has not run" below is checked
// at a point the arm has definitely reached rather than at whatever point a
// 5s poll happened to stop at.
await bus.reached("armed");
bus.close();
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard ran before the watch arm could establish supervision");
  process.exit(1);
}
if (promptBody) {
  console.error(`unexpected prompt: ${promptBody}`);
  process.exit(1);
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode turn-end guard must let the auto-arm plugin establish supervision first"
  [ -z "$out" ] || fail "OpenCode coordination test printed output: $out"
  pass "OpenCode watcher plugin coordinates with the turn-end guard"
}

test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local arm_plugin guard_plugin repo home log guard_log bus out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-root"
  home="$TMP_ROOT/opencode-external-healthy-home"
  log="$TMP_ROOT/opencode-external-healthy-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-guard.log"
  bus="$TMP_ROOT/opencode-external-healthy.bus"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  fm_checkpoint_bus "$bus"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'armed %s\n' "$$" > "${FM_CHECKPOINT_BUS:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
const promptBodies = [];
const client = {
  session: {
    promptAsync: async (request) => {
      promptBodies.push(request.body.parts[0].text);
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
// The guard hook awaits its whole path - the arm coordination, the guard
// script, and the blind-turn prompt - so awaiting the hook already covers
// everything asserted about the guard. The old loop instead polled for the
// guard log file and then immediately asserted on a prompt that is sent
// after it, which is a race the poll length cannot fix.
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
// The arm child is the one thing still running outside that awaited path, so
// it announces its own row.
await bus.reached("armed");
bus.close();
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBodies.some((body) => body.includes("TURN WOULD END BLIND"))) {
  console.error(`missing blind-turn prompt: ${promptBodies.join("\n---\n")}`);
  process.exit(1);
}
EOF
)
  status=$?
  # Output first: the driver reports what it saw on stderr, and checking the
  # exit code first would abort before that diagnosis is ever printed.
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm"
  pass "OpenCode healthy arm output does not suppress the turn-end guard"
}

test_tracked_extension_present_and_self_hashing
test_spawn_template_mentions_pi_watch_placeholder
test_pi_extension_reports_external_healthy_watcher
test_pi_tool_returns_agent_tool_result
test_pi_redundant_tool_call_is_owned_noop
test_pi_scheduled_retry_call_is_owned_noop
test_pi_actionable_close_starts_single_successor_before_delivery
test_pi_hung_successor_falls_back_to_typed_wake
test_pi_unretired_successor_falls_back_without_retry
test_pi_late_unretired_close_resumes_supervision
test_pi_empty_close_retries_instead_of_disappearing
test_pi_established_empty_close_honors_retry_limit
test_pi_actionable_close_rechecks_session_lock
test_pi_arm_distinguishes_session_lock_ownership
test_pi_session_transition_generation_owner
test_pi_process_exit_cleanup_listener_lifecycle
test_pi_process_exit_cleanup_stops_arm_child
test_opencode_plugin_package_boundary_is_explicit_esm
test_opencode_primary_watch_plugin_uses_effective_state_home
test_opencode_primary_watch_plugin_sources_effective_config
test_opencode_primary_watch_plugin_requires_session_lock
test_opencode_watch_arm_coordinator_respects_primary_scope
test_opencode_primary_watch_plugin_rearms_after_wake
test_opencode_pre_ready_actionable_close_preserves_its_successor
test_opencode_undetermined_primacy_probe_retries_instead_of_abandoning
test_opencode_hung_successor_falls_back_to_typed_wake
test_opencode_unretired_successor_falls_back_without_retry
test_opencode_late_unretired_close_resumes_supervision
test_opencode_empty_close_retries_instead_of_disappearing
test_opencode_established_empty_close_honors_retry_limit
test_opencode_actionable_close_rechecks_session_lock
test_opencode_watch_arm_coordinates_with_turnend_guard
test_opencode_healthy_arm_output_does_not_suppress_guard
