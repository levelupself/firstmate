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
# name until that announcement arrives. No iteration count, no interval, and
# no deadline is involved, so a slow machine makes the test slower rather than
# wrong.
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

// Every checkpoint currently being waited on, by label. A checkpoint that
// never arrives stalls rather than failing, which is the whole point: there
// is no deadline left to get wrong. The cost of that is that a genuine
// regression stops instead of reporting, so name what is outstanding when the
// run is cut short. A stalled driver then still says what never signalled.
const outstanding = new Set();
let reporterInstalled = false;

function reportOutstanding() {
  if (outstanding.size > 0) {
    process.stderr.write(`checkpoint never reached: ${[...outstanding].join(", ")}\n`);
  }
}

function watchForOutstanding(label) {
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
  }
  outstanding.add(label);
}

// Opening a FIFO read-write keeps a writer end held inside this process, so
// the read side neither blocks waiting for the first fixture nor sees EOF
// between one fixture closing and the next one opening.
export function openCheckpointBus(path) {
  const socket = new Socket({ fd: openSync(path, "r+"), readable: true, writable: false });
  socket.setEncoding("utf8");
  // The bus keeps the event loop alive only while something is waiting on it,
  // so a driver that has finished its checkpoints still exits on its own.
  socket.unref();

  const arrived = new Map();
  const waiters = new Map();
  let buffered = "";
  let awaiting = 0;

  const queueFor = (map, name) => {
    const queue = map.get(name) ?? [];
    map.set(name, queue);
    return queue;
  };

  const settle = (name, resolve, payload) => {
    awaiting -= 1;
    if (awaiting === 0) socket.unref();
    if (queueFor(waiters, name).length === 0) outstanding.delete(`bus:${name}`);
    resolve(payload);
  };

  socket.on("data", (chunk) => {
    buffered += chunk;
    let cut = buffered.indexOf("\n");
    while (cut !== -1) {
      const line = buffered.slice(0, cut).trim();
      buffered = buffered.slice(cut + 1);
      if (line) {
        const gap = line.indexOf(" ");
        const name = gap === -1 ? line : line.slice(0, gap);
        const payload = gap === -1 ? "" : line.slice(gap + 1).trim();
        const waiting = queueFor(waiters, name);
        // An announcement that nobody is waiting on yet is kept rather than
        // dropped: a fixture is allowed to reach its checkpoint before the
        // driver gets around to asking about it, and two announcements can
        // arrive inside a single read.
        if (waiting.length > 0) settle(name, waiting.shift(), payload);
        else queueFor(arrived, name).push(payload);
      }
      cut = buffered.indexOf("\n");
    }
  });

  return {
    // Resolve with the payload of the next unconsumed announcement of <name>.
    // Repeated checkpoints of the same name are consumed in arrival order, so
    // a fixture that reaches the same point several times can be stepped
    // through one occurrence at a time.
    reached(name) {
      const ready = queueFor(arrived, name);
      if (ready.length > 0) return Promise.resolve(ready.shift());
      awaiting += 1;
      socket.ref();
      watchForOutstanding(`bus:${name}`);
      return new Promise((resolve) => queueFor(waiters, name).push(resolve));
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

// Hold the event loop open for as long as something is waiting on an
// in-process checkpoint. Without this, Node can decide a driver is finished
// while the very signal it is waiting for is still in flight, and the old
// polling loops were accidentally doing this job with their tick timers. The
// interval never fires and bounds nothing; it only keeps the process alive.
function keepAlive() {
  let held = 0;
  let handle = null;
  return {
    hold() {
      held += 1;
      if (handle === null) handle = setInterval(() => {}, 2147483647);
    },
    release() {
      held -= 1;
      if (held === 0 && handle !== null) {
        clearInterval(handle);
        handle = null;
      }
    },
  };
}

// An in-process checkpoint, for the case where the announcing side is a stub
// this driver owns rather than a separate process. Same contract as the bus:
// the other side signals, and the waiter blocks on the signal.
export function latch(label = "latch") {
  const alive = keepAlive();
  let settled = false;
  let held = false;
  let resolve;
  const promise = new Promise((settle) => {
    resolve = settle;
  });
  return {
    // Signalling twice is a fixture detail, not an error: only the first one
    // settles the checkpoint, and later ones must not unbalance the hold.
    signal(value) {
      if (settled) return;
      settled = true;
      if (held) {
        alive.release();
        outstanding.delete(label);
      }
      resolve(value);
    },
    // Reading this is what declares interest, so a latch nobody waits on -
    // the losing side of a race, say - never holds the process open.
    get reached() {
      if (!settled && !held) {
        held = true;
        alive.hold();
        watchForOutstanding(label);
      }
      return promise;
    },
  };
}

// A latch that counts. Await the nth occurrence of a repeated in-process
// event without polling for a counter to move.
export function counter(label = "counter") {
  const alive = keepAlive();
  const waiters = [];
  let count = 0;
  return {
    bump() {
      count += 1;
      while (waiters.length > 0 && waiters[0].target <= count) {
        alive.release();
        const waiter = waiters.shift();
        outstanding.delete(waiter.key);
        waiter.resolve(count);
      }
    },
    get count() {
      return count;
    },
    reached(target) {
      if (count >= target) return Promise.resolve(count);
      const key = `${label}>=${target}`;
      alive.hold();
      watchForOutstanding(key);
      return new Promise((resolve) => {
        waiters.push({ target, key, resolve });
        waiters.sort((a, b) => a.target - b.target);
      });
    },
  };
}
MJS
  fi
  printf '%s\n' "$file"
}
