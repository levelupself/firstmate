#!/usr/bin/env bash
# Shared signal-based checkpoint helper for tests that drive a fixture process
# and then have to know when that fixture reached a particular point.
#
# The problem this replaces: a waiter that sleeps, or polls a predicate for a
# fixed number of iterations, has silently encoded a guess about how long the
# other side takes. On a loaded CI box the guess is wrong and the test fails
# with a message about the assertion rather than about the deadline.
#
# The contract here inverts that. The fixture announces each point it reaches
# by writing one line to a named-checkpoint bus, and the waiter blocks on the
# name until that announcement arrives. No iteration count, interval, or
# deadline decides the wait's assertion, so a slow machine makes the test
# slower rather than wrong.
#
# Bus wire format, one checkpoint per line:
#
#   <name>[ <payload>]
#
# The name is the first whitespace-delimited token and the payload is the rest
# of the line. Lines stay well under PIPE_BUF so concurrent fixture writes
# interleave whole lines rather than fragments.
#
# Fixture side, from any shell script, with no sourcing required:
#
#   printf 'successor-ready %s\n' "$$" > "$FM_CHECKPOINT_BUS"
#
# Waiter side, from a Node driver:
#
#   const bus = openCheckpointBus(process.env.FM_CHECKPOINT_BUS);
#   const pid = await bus.reached("successor-ready");
#
# What this helper deliberately does NOT do: it does not replace a wait that
# exists to observe that something does NOT happen. A negative window needs a
# duration by construction, because the absence of an event is only meaningful
# over some span of time. Those waits belong exactly where they are.
#
# The trade a checkpoint used to make, and no longer makes. A deadline turns a
# slow machine into a false failure but turns a real regression into a fast,
# well-worded one. A bare checkpoint removes the false failure and turns that
# same regression into a stall: measured here by removing the Pi extension's
# retry-exhaustion wake, the deadline version failed in about 2.5s naming the
# missing wake, and the checkpoint version ran until it was killed.
#
# Two guarantees close that gap, and between them a checkpoint that cannot be
# satisfied is always reported rather than waited on. Neither is a deadline:
# neither one decides an assertion, and a slow machine only makes the run
# slower.
#
# 1. Liveness. A checkpoint can only be announced by something that can still
#    run - a live fixture process, or a pending timer that will start or signal
#    one. Node already tracks both: a live child holds its stdio handles open,
#    and this module counts pending timers. When neither remains and a wait is
#    still outstanding, nothing in this process or under it will ever satisfy
#    that wait, so it is rejected by name instead of waited on forever. The
#    condition is exact and event-driven, and it holds for a fixture that was
#    killed rather than exited, because the kernel closes a dead process's
#    handles whatever killed it.
#
# 2. Watchdog. Liveness cannot see a fixture that never dies - one blocked
#    writing to a bus whose reader has closed, say, which keeps its parent
#    alive through the very handles liveness reads. That leaves the run alive
#    with nothing outstanding and nothing to report, which is silence to the
#    job cap. One idle-time watchdog per driver, reset by every checkpoint,
#    prints what is outstanding and which fixtures are still alive, then exits
#    non-zero. It can only turn silence into a named report; it can never pass
#    a test. FM_CHECKPOINT_WATCHDOG_MS overrides its idle bound.
#
# The module also carries the process-death poll, which stays a poll on purpose.

# fm_checkpoint_bus <path>
#   Create the checkpoint bus FIFO at <path>, replacing any stale one. Export
#   the path to both the fixture and the Node driver as FM_CHECKPOINT_BUS.
fm_checkpoint_bus() {
  local path=$1
  rm -f "$path"
  mkfifo "$path"
}

# fm_checkpoint_module <dir>
#   Materialize the Node checkpoint-bus module under <dir> and print its path.
#   Drivers import it by absolute path, so <dir> only needs to be writable and
#   to outlive the driver.
fm_checkpoint_module() {
  local dir=$1 file
  file="$dir/fm-checkpoint-bus.mjs"
  if [ ! -f "$file" ]; then
    cat > "$file" <<'MJS'
// Named-checkpoint bus reader. See tests/fm-checkpoint-helpers.sh for the
// wire format and for why this exists.
import { openSync } from "node:fs";
import { Socket } from "node:net";

// Deliberately still a bounded poll, and only ever used for "this pid is
// gone". A dying process cannot announce its own death: anything it writes is
// necessarily sent before it exits, so a checkpoint here would downgrade the
// assertion from "the previous child is gone" to "the previous child intended
// to go". That is exactly the kind of weakening this sweep exists to avoid,
// so the arrival of a new child is a checkpoint while the departure of an old
// one stays an observation.
export async function waitForExit(pid, label, attempts = 250) {
  for (let i = 0; i < attempts; i += 1) {
    try {
      process.kill(Number(pid), 0);
    } catch {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

// Every checkpoint currently being waited on, by label, with the rejecters
// that are settled if it becomes unreachable. See the liveness and watchdog
// guarantees in tests/fm-checkpoint-helpers.sh for why both exist.
const outstanding = new Map();
let reporterInstalled = false;
let reported = false;

// Node reports neither an unreferenced pending timer nor one that a driver has
// stubbed out, so count them here. A pending timer is the one way work can
// still start when no fixture is alive - the extension schedules its continuity
// retries exactly that way - and treating that gap as unreachable would reject
// a checkpoint that is genuinely still coming.
const nativeSetTimeout = globalThis.setTimeout;
const nativeClearTimeout = globalThis.clearTimeout;
const countedTimers = new WeakSet();
let pendingTimers = 0;

// A driver may stub setTimeout to seize a specific delay, in which case the
// callback fires by hand and never through a real timer. Count only what the
// underlying implementation returns as a genuine Timeout.
function isRealTimer(timer) {
  return Boolean(timer) && typeof timer === "object" && typeof timer.refresh === "function";
}

function releaseTimer(timer) {
  if (!countedTimers.delete(timer)) return;
  pendingTimers -= 1;
}

globalThis.setTimeout = (callback, delay, ...args) => {
  if (typeof callback !== "function") return nativeSetTimeout(callback, delay, ...args);
  let timer = null;
  const settle = (...called) => {
    releaseTimer(timer);
    return callback(...called);
  };
  timer = nativeSetTimeout(settle, delay, ...args);
  if (isRealTimer(timer)) {
    countedTimers.add(timer);
    pendingTimers += 1;
  }
  return timer;
};

globalThis.clearTimeout = (timer) => {
  releaseTimer(timer);
  return nativeClearTimeout(timer);
};

function outstandingLabels() {
  return [...outstanding.keys()];
}

function liveFixturePids() {
  let handles = [];
  try {
    handles = process._getActiveHandles();
  } catch {
    return [];
  }
  return handles
    .filter((handle) => handle && typeof handle.pid === "number" && handle.pid !== process.pid)
    .map((handle) => handle.pid);
}

function reportOutstanding() {
  // A signal handler that calls process.exit also fires the exit hook, so
  // report once however the run ends.
  if (reported || outstanding.size === 0) return;
  reported = true;
  process.stderr.write(`checkpoint never reached: ${outstandingLabels().join(", ")}\n`);
}

// Settle every outstanding wait as unreachable. Called only from the liveness
// check below, which has already established that nothing can announce.
function rejectOutstanding(reason) {
  const rejecters = [...outstanding.values()].flatMap((waiters) => [...waiters]);
  const labels = outstandingLabels();
  outstanding.clear();
  reported = true;
  const failure = new Error(`checkpoint can never arrive: ${labels.join(", ")} - ${reason}`);
  for (const reject of rejecters) reject(failure);
}

// Nothing is running that could announce a checkpoint: no fixture holds a
// handle open, and no timer is pending to start one. Node is about to exit, so
// this is the exact moment the wait became unreachable rather than slow.
//
// Two things can still be in flight at that moment and neither is a guess: a
// pending timer, which is counted above, and a line already written to the bus
// that this process has not polled yet. Yielding the loop a turn settles both,
// and idleTurns only ever delays the verdict.
let idleTurns = 0;

function noteProgress() {
  idleTurns = 0;
  armWatchdog();
}

function yieldOneTurn() {
  // A referenced timer this module does not count, purely to give the loop one
  // more turn so anything already in flight can land.
  nativeSetTimeout(() => {}, 1);
}

function checkLiveness() {
  if (outstanding.size === 0) return;
  if (pendingTimers > 0) {
    // Work is still scheduled, so the verdict is not due yet. Timers do not
    // advance the idle count: only turns with nothing pending at all do.
    yieldOneTurn();
    return;
  }
  if (idleTurns < 2) {
    idleTurns += 1;
    yieldOneTurn();
    return;
  }
  rejectOutstanding("no live fixture process and no pending timer can still announce it");
}

// One idle-time bound per driver, for the case liveness cannot see: a fixture
// that never dies keeps this process alive through its own stdio handles, so
// the loop never empties and no checkpoint is left outstanding to name. Kept
// unreferenced so it never holds the process open and never masks liveness.
const watchdogMs = Number(process.env.FM_CHECKPOINT_WATCHDOG_MS) > 0
  ? Number(process.env.FM_CHECKPOINT_WATCHDOG_MS)
  : 120000;
let watchdog = null;

function armWatchdog() {
  if (watchdog) nativeClearTimeout(watchdog);
  watchdog = nativeSetTimeout(() => {
    const waiting = outstanding.size > 0 ? outstandingLabels().join(", ") : "nothing";
    const pids = liveFixturePids();
    const alive = pids.length > 0 ? pids.join(", ") : "none";
    process.stderr.write(
      `checkpoint watchdog: no checkpoint activity for ${watchdogMs}ms; outstanding: ${waiting}; live fixture pids: ${alive}\n`,
    );
    process.exit(1);
  }, watchdogMs);
  watchdog.unref();
}

function watchForOutstanding(label, reject) {
  if (!reporterInstalled) {
    reporterInstalled = true;
    for (const signal of ["SIGTERM", "SIGINT"]) {
      process.on(signal, () => {
        reportOutstanding();
        process.exit(1);
      });
    }
    // Node giving up on its own - an unsettled top-level await - is the other
    // way a checkpoint can fail to arrive, and it deserves the same naming.
    process.on("exit", reportOutstanding);
    process.on("beforeExit", checkLiveness);
  }
  noteProgress();
  const waiters = outstanding.get(label) ?? new Set();
  outstanding.set(label, waiters);
  waiters.add(reject);
}

function clearOutstanding(label, reject) {
  const waiters = outstanding.get(label);
  if (!waiters) return;
  waiters.delete(reject);
  if (waiters.size === 0) outstanding.delete(label);
}

// Opening a FIFO read-write keeps a writer end held inside this process, so
// the read side neither blocks waiting for the first fixture nor sees EOF
// between one fixture closing and the next one opening.
export function openCheckpointBus(path) {
  const socket = new Socket({ fd: openSync(path, "r+"), readable: true, writable: false });
  socket.setEncoding("utf8");
  // The bus never holds the event loop open. Whatever is going to announce a
  // checkpoint is what keeps this process alive - a live fixture through its
  // stdio handles, or a pending timer - and when none of that is left the
  // liveness check names the wait instead of holding the run open on its own.
  socket.unref();

  const arrived = new Map();
  const waiters = new Map();
  let buffered = "";

  const queueFor = (map, name) => {
    const queue = map.get(name) ?? [];
    map.set(name, queue);
    return queue;
  };

  socket.on("data", (chunk) => {
    buffered += chunk;
    let cut = buffered.indexOf("\n");
    while (cut !== -1) {
      const line = buffered.slice(0, cut).trim();
      buffered = buffered.slice(cut + 1);
      if (line) {
        noteProgress();
        const gap = line.indexOf(" ");
        const name = gap === -1 ? line : line.slice(0, gap);
        const payload = gap === -1 ? "" : line.slice(gap + 1).trim();
        const waiting = queueFor(waiters, name);
        // An announcement that nobody is waiting on yet is kept rather than
        // dropped: a fixture is allowed to reach its checkpoint before the
        // driver gets around to asking about it, and two announcements can
        // arrive inside a single read.
        if (waiting.length > 0) {
          const waiter = waiting.shift();
          clearOutstanding(`bus:${name}`, waiter.reject);
          waiter.resolve(payload);
        } else {
          queueFor(arrived, name).push(payload);
        }
      }
      cut = buffered.indexOf("\n");
    }
  });

  return {
    // Resolve with the payload of the next unconsumed announcement of <name>.
    // Repeated checkpoints of the same name are consumed in arrival order, so
    // a fixture that reaches the same point several times can be stepped
    // through one occurrence at a time. Rejects, naming <name>, when nothing
    // is left that could announce it.
    reached(name) {
      const ready = queueFor(arrived, name);
      if (ready.length > 0) {
        noteProgress();
        return Promise.resolve(ready.shift());
      }
      return new Promise((resolve, reject) => {
        queueFor(waiters, name).push({ resolve, reject });
        watchForOutstanding(`bus:${name}`, reject);
      });
    },
    // True when <name> has an unconsumed announcement already in hand. Use it
    // to read a checkpoint's arrival without waiting on it.
    seen(name) {
      return (arrived.get(name) ?? []).length > 0;
    },
    close() {
      socket.destroy();
    },
  };
}

// An in-process checkpoint, for the case where the announcing side is a stub
// this driver owns rather than a separate process. Same contract as the bus:
// the other side signals, and the waiter blocks on the signal. Nothing here
// holds the event loop open either - whatever drives the stub is what keeps
// this process alive, and when that is gone the wait is named rather than
// held.
export function latch(label = "latch") {
  let settled = false;
  let held = false;
  let resolve;
  let reject;
  const promise = new Promise((settleWith, failWith) => {
    resolve = settleWith;
    reject = failWith;
  });
  // Nobody may be reading this latch yet, and an unobserved rejection is a
  // crash rather than a report. Reading it removes the guard.
  promise.catch(() => {});
  return {
    // Signalling twice is a fixture detail, not an error: only the first one
    // settles the checkpoint, and later ones must not unbalance the hold.
    signal(value) {
      noteProgress();
      if (settled) return;
      settled = true;
      if (held) clearOutstanding(label, reject);
      resolve(value);
    },
    // Reading this is what declares interest, so a latch nobody waits on -
    // the losing side of a race, say - is never reported as unreachable.
    get reached() {
      if (!settled && !held) {
        held = true;
        watchForOutstanding(label, reject);
      }
      return promise;
    },
  };
}

// A latch that counts. Await the nth occurrence of a repeated in-process
// event without polling for a counter to move.
export function counter(label = "counter") {
  const waiters = [];
  let count = 0;
  return {
    bump() {
      noteProgress();
      count += 1;
      while (waiters.length > 0 && waiters[0].target <= count) {
        const waiter = waiters.shift();
        clearOutstanding(waiter.key, waiter.reject);
        waiter.resolve(count);
      }
    },
    get count() {
      return count;
    },
    reached(target) {
      if (count >= target) {
        noteProgress();
        return Promise.resolve(count);
      }
      const key = `${label}>=${target}`;
      return new Promise((resolve, reject) => {
        waiters.push({ target, key, resolve, reject });
        waiters.sort((a, b) => a.target - b.target);
        watchForOutstanding(key, reject);
      });
    },
  };
}
MJS
  fi
  printf '%s\n' "$file"
}
