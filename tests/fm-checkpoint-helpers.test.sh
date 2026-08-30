#!/usr/bin/env bash
# Tests for the shared checkpoint bus in tests/fm-checkpoint-helpers.sh.
#
# The subject is the guarantee that a checkpoint nothing can satisfy is
# reported by name instead of waited on. Every case below drives the helper
# through a real fixture process, because the whole question is what happens
# when a separate process dies without announcing.
#
# Never write an apostrophe inside the Node driver heredocs below, comments
# included: each one sits inside an out=$(...) command substitution, and stock
# macOS Bash 3.2 tracks quote characters straight through a heredoc body while
# Bash 4 and later do not. See the same warning in
# tests/fm-pi-watch-extension.test.sh for the failure it produces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-checkpoint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-checkpoint-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-checkpoint-helpers)
CHECKPOINT_MODULE=$(fm_checkpoint_module "$TMP_ROOT")
export NODE_NO_WARNINGS=1

test_wait_is_named_when_the_only_fixture_exits_without_announcing() {
  local bus out status
  bus="$TMP_ROOT/exit-without-announcing.bus"
  fm_checkpoint_bus "$bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
// The one process that could announce reaches its exit without doing so, so
// after it is gone nothing in this process or under it can ever satisfy the
// wait below.
spawn("bash", ["-c", "exit 0"], { stdio: ["ignore", "pipe", "pipe"] });
await bus.reached("never-announced");
process.stdout.write("the unreachable wait resolved\n");
EOF
)
  status=$?
  [ "$status" -ne 0 ] || fail "unreachable checkpoint did not fail the driver"
  assert_contains "$out" "checkpoint can never arrive: bus:never-announced" \
    "unreachable checkpoint was not named"
  pass "a wait no surviving fixture can announce is named instead of held open"
}

test_wait_is_named_when_the_fixture_is_killed_rather_than_exiting() {
  local bus out status
  bus="$TMP_ROOT/killed-fixture.bus"
  fm_checkpoint_bus "$bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
// SIGKILL runs no trap of any kind, so no announcement is possible on this
// path however the fixture is written. The kernel closing the dead process
// handles is the only signal left, and it is the one this has to work from.
const fixture = spawn("bash", ["-c", "sleep 30"], { stdio: ["ignore", "pipe", "pipe"] });
setTimeout(() => fixture.kill("SIGKILL"), 20);
await bus.reached("killed-before-announcing");
process.stdout.write("the unreachable wait resolved\n");
EOF
)
  status=$?
  [ "$status" -ne 0 ] || fail "killed fixture did not fail the driver"
  assert_contains "$out" "checkpoint can never arrive: bus:killed-before-announcing" \
    "checkpoint left unreachable by a killed fixture was not named"
  pass "a fixture killed rather than exited still ends its checkpoint by name"
}

test_pending_timer_is_not_mistaken_for_an_unreachable_wait() {
  local bus out status
  bus="$TMP_ROOT/retry-gap.bus"
  fm_checkpoint_bus "$bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
// The shape the watcher extension uses to restore continuity: no fixture is
// alive at all, and the only thing that will start one is an unreferenced
// timer. Treating that gap as unreachable would reject a checkpoint that is
// genuinely still coming, so this is the case the liveness rule must not fire
// on.
const gap = setTimeout(() => {
  spawn("bash", ["-c", "printf 'late-arm 7\\n' > \"$FM_CHECKPOINT_BUS\""], {
    stdio: ["ignore", "pipe", "pipe"],
  });
}, 200);
gap.unref();
const payload = await bus.reached("late-arm");
if (payload !== "7") throw new Error(`late arm announced ${payload}, expected 7`);
EOF
)
  status=$?
  [ -z "$out" ] || fail "retry-gap test printed output: $out"
  expect_code 0 "$status" "a checkpoint behind a pending timer must still be awaited"
  pass "a checkpoint still reachable through a pending timer is awaited, not rejected"
}

test_watchdog_names_a_fixture_that_pins_the_driver_without_dying() {
  local blocked_bus bus fixture_pid gate out status watchdog_pids
  bus="$TMP_ROOT/pinned-driver.bus"
  blocked_bus="$TMP_ROOT/pinned-writer.bus"
  gate="$TMP_ROOT/pinned-driver.gate"
  fm_checkpoint_bus "$bus"
  fm_checkpoint_bus "$blocked_bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_GATE="$gate" \
    FM_BLOCKED_BUS="$blocked_bus" \
    FM_CHECKPOINT_WATCHDOG_MS=10000 node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { closeSync, openSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const blockedReader = openSync(process.env.FM_BLOCKED_BUS, "r+");
// The checkpoint bus stays open, but the fixture writes next to a different
// FIFO after its reader closes. This preserves a direct watchdog control for
// a pinned live fixture without violating the close-order guarantee under
// test: the helper bus itself is never closed while its announcer is alive.
const fixture = spawn(
  "bash",
  [
    "-c",
    "printf 'ready 1\\n' > \"$FM_CHECKPOINT_BUS\"; while [ ! -e \"$FM_GATE\" ]; do sleep 0.02; done; printf 'blocked 1\\n' > \"$FM_BLOCKED_BUS\"",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
await bus.reached("ready");
closeSync(blockedReader);
writeFileSync(process.env.FM_GATE, "go\n");
process.stdout.write(`pinned by ${fixture.pid}\n`);
EOF
)
  status=$?
  [ "$status" -ne 0 ] || fail "pinned driver did not fail"
  assert_contains "$out" "checkpoint watchdog: no checkpoint activity for 10000ms" \
    "watchdog did not report the pinned driver"
  assert_contains "$out" "outstanding: nothing" \
    "watchdog did not report that no checkpoint was outstanding"
  fixture_pid=$(printf '%s\n' "$out" | sed -n 's/^pinned by //p')
  [ -n "$fixture_pid" ] || fail "driver did not print the pinned fixture pid: $out"
  watchdog_pids=$(printf '%s\n' "$out" | sed -n 's/^.*live fixture pids: //p' | tr -d ' ')
  case ",$watchdog_pids," in
    *",$fixture_pid,"*) ;;
    *) fail "watchdog did not name pinned fixture $fixture_pid: $out" ;;
  esac
  pass "a fixture that pins the driver without dying is named by the watchdog"
}

test_historical_close_order_reproduces_the_blocked_writer_failure() {
  local bus gate out status
  bus="$TMP_ROOT/historical-closed.bus"
  gate="$TMP_ROOT/historical-closed.gate"
  fm_checkpoint_bus "$bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_GATE="$gate" node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { openSync, writeFileSync } from "node:fs";
import { Socket } from "node:net";

const socket = new Socket({ fd: openSync(process.env.FM_CHECKPOINT_BUS, "r+"), readable: true, writable: false });
socket.setEncoding("utf8");
const fixture = spawn(
  "bash",
  [
    "-c",
    "printf 'ready 1\\n' > \"$FM_CHECKPOINT_BUS\"; while [ ! -e \"$FM_GATE\" ]; do sleep 0.02; done; printf 'attempting late\\n' >&2; printf 'late 1\\n' > \"$FM_CHECKPOINT_BUS\"; printf 'completed late\\n' >&2",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
let buffered = "";
await new Promise((resolve) => {
  socket.on("data", (chunk) => {
    buffered += chunk;
    if (buffered.includes("ready 1\n")) resolve();
  });
});
socket.destroy();
writeFileSync(process.env.FM_GATE, "go\n");
let stderr = "";
fixture.stderr.setEncoding("utf8");
fixture.stderr.on("data", (chunk) => { stderr += chunk; });
await new Promise((resolve) => setTimeout(resolve, 100));
if (!stderr.includes("attempting late\n")) throw new Error("fixture never attempted the late checkpoint write");
if (stderr.includes("completed late\n") || fixture.exitCode !== null) {
  throw new Error("blocked-writer detector did not detect the historical failure");
}
fixture.kill("SIGKILL");
await new Promise((resolve) => fixture.once("close", resolve));
throw new Error("fixture became a blocked writer on a closed checkpoint bus");
EOF
)
  status=$?
  [ "$status" -ne 0 ] || fail "historical close order did not reproduce the blocked writer failure"
  assert_contains "$out" "fixture became a blocked writer on a closed checkpoint bus" \
    "historical blocked-writer failure was not preserved"
  assert_not_contains "$out" "blocked-writer detector did not detect" \
    "historical blocked-writer positive control did not detect the bad state"
  pass "historical close order visibly reproduces the blocked writer failure"
}

test_bus_refuses_to_close_while_a_fixture_can_still_announce() {
  local bus gate out status
  bus="$TMP_ROOT/live-announcer.bus"
  gate="$TMP_ROOT/live-announcer.gate"
  fm_checkpoint_bus "$bus"
  out=$(FM_CHECKPOINT_BUS="$bus" FM_CHECKPOINT_MODULE="$CHECKPOINT_MODULE" FM_GATE="$gate" \
    FM_CHECKPOINT_WATCHDOG_MS=1000 node --input-type=module 2>&1 <<'EOF'
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const { openCheckpointBus, waitForExit } = await import(pathToFileURL(process.env.FM_CHECKPOINT_MODULE).href);
const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
const fixture = spawn(
  "bash",
  [
    "-c",
    "printf 'ready 1\\n' > \"$FM_CHECKPOINT_BUS\"; while [ ! -e \"$FM_GATE\" ]; do sleep 0.02; done; printf 'late 1\\n' > \"$FM_CHECKPOINT_BUS\"",
  ],
  { stdio: ["ignore", "pipe", "pipe"] },
);
await bus.reached("ready");
let refusal = null;
try {
  bus.close();
} catch (error) {
  refusal = error;
}
if (!refusal) throw new Error("checkpoint bus closed while a fixture could still announce");
if (!refusal.message.includes(`refusing to close checkpoint bus while fixture processes are alive: ${fixture.pid}`)) {
  throw refusal;
}
writeFileSync(process.env.FM_GATE, "go\n");
await bus.reached("late");
await waitForExit(fixture.pid, "live-announcer fixture exit");
await bus.waitForNoFixtures();
bus.close();
EOF
)
  status=$?
  expect_code 0 "$status" "checkpoint bus close must reject a live announcer and permit close after it exits"
  [ -z "$out" ] || fail "live-announcer close test printed output: $out"
  pass "checkpoint bus close visibly rejects a live announcer and succeeds once none remain"
}

test_wait_is_named_when_the_only_fixture_exits_without_announcing
test_wait_is_named_when_the_fixture_is_killed_rather_than_exiting
test_pending_timer_is_not_mistaken_for_an_unreachable_wait
test_watchdog_names_a_fixture_that_pins_the_driver_without_dying
test_historical_close_order_reproduces_the_blocked_writer_failure
test_bus_refuses_to_close_while_a_fixture_can_still_announce
