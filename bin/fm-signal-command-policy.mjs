#!/usr/bin/env node
// Semantic policy for the crew signal guard: may this shell command signal the
// processes it targets?
//
// A crew session must never signal a process it cannot prove it started. The
// rule is an ALLOW rule, not a deny list: every signal target must resolve,
// before the command runs, to a process inside this session's own process
// tree - a live descendant of the agent process, or an orphaned background job
// that still carries this session's process-scope marker (FM_PROC_SCOPE, set by
// bin/fm-spawn.sh on the agent launch) - and never the agent itself or any of
// its ancestors. Targets that exist only at run time (a pattern search, a
// parent PID, a loop or stdin variable) cannot be proven and are denied, and
// tools that select targets by name are denied outright. See docs/signal-guard.md
// for the full contract; bin/fm-signal-pretool-check.sh is the harness
// transport.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification. This policy never evaluates, expands, sources, or runs any
// byte of the submitted command. Its only side effects are reading the process
// table, the environment of candidate processes, and a PID file the command
// names.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { readFileSync, statSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCOPE_VARIABLE = "FM_PROC_SCOPE";
const SCOPE_PATTERN = /^[A-Za-z0-9._:-]{1,256}$/;

const SAFE_WAY =
  "Signal only a process this session started: use $! (or a variable assigned from $!) in the same command, a job spec such as %1, $(jobs -p), kill \"$(cat /abs/path/job.pid)\" for a PID file this session wrote when it launched the job (cmd & echo $! > /abs/path/job.pid), or a literal PID confirmed with ps; the guard verifies that literal and PID-file targets belong to this session's own process tree.";

const LEAVE_OTHERS =
  "This session may signal only processes it started: live descendants of its agent process, or its orphaned background jobs that still carry its process-scope marker. Leave every other process alone - the agent itself, its shells, the terminal server, and the service manager included; if one of them must be stopped, report it instead of signalling it.";

const REASONS = {
  "signal-unclassifiable": `the command mentions a process-signalling tool but uses shell syntax this guard cannot parse, so it cannot prove the target is a process this session started. Put the signal in its own simple command. ${SAFE_WAY}`,
  "signal-by-name": `pkill, killall, skill, killall5, and fuser -k choose their targets by name or pattern, which can match processes this session did not start, including the shared terminal server and the user service manager every worker depends on. ${SAFE_WAY}`,
  "signal-broadcast": `kill -1 signals every process this user owns and kill 0 signals the caller's whole process group, which can include the agent itself. ${SAFE_WAY}`,
  "signal-unprovable-target": `the signal target is computed at run time - a pattern search (ps | grep, pgrep, pidof), a parent PID ($PPID or a ppid column), a loop, read, or stdin variable, or another substitution - so the guard cannot prove it is a process this session started, and signalling a matched process's parent can take down the shared terminal server or the user service manager. ${SAFE_WAY}`,
  "signal-no-scope": `this session's process-scope marker (${SCOPE_VARIABLE}) was not found on any of its ancestor processes, so the guard cannot verify that a literal or PID-file target is a process this session started. Within one command, $!, a variable assigned from $!, a job spec, and $(jobs -p) still work; anything else needs a worker launched through fm-spawn, which sets the marker.`,
  "signal-unverifiable": "the guard could not read the process table to verify the signal target, so it refuses rather than guessing. Retry once; if it keeps failing, report it instead of signalling.",
  "signal-outside-session": LEAVE_OTHERS,
};

// Tools that pick their targets by name, pattern, user, or resource.
const BY_NAME_TOOLS = new Set(["pkill", "killall", "skill", "killall5"]);
const BY_NAME_HARMLESS_ARGS = new Set(["-h", "--help", "-V", "--version", "-l", "--list"]);

// Reserved words that may precede a command word in one list node.
const RESERVED_PREFIXES = new Set(["!", "if", "then", "else", "elif", "while", "until", "do", "time"]);

// Shells whose -c payload, heredoc, or here-string is itself a shell program.
const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh", "mksh"]);

// Wrappers commandPosition does not already skip, each with the options that
// consume a separate argument. xargs additionally feeds its command's
// operands from stdin.
const EXTRA_WRAPPERS = {
  builtin: new Set(),
  nice: new Set(["-n", "--adjustment"]),
  setsid: new Set(),
  stdbuf: new Set(["-i", "-o", "-e", "--input", "--output", "--error"]),
  ionice: new Set(["-c", "-n", "--class", "--classdata"]),
  time: new Set(["-f", "-o", "--format", "--output"]),
  doas: new Set(["-u", "-C"]),
  unbuffer: new Set(),
  xargs: new Set(["-a", "-d", "-E", "-I", "-L", "-n", "-P", "-s", "--arg-file", "--delimiter", "--eof", "--max-lines", "--max-args", "--max-procs", "--max-chars", "--process-slot-var"]),
};

const FIND_EXEC_ACTIONS = new Set(["-exec", "-execdir", "-ok", "-okdir"]);

function commandName(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function mentionsSignalTool(text) {
  return /kill|fuser/.test(text.replace(/\\\r?\n/g, "").replace(/["'\\]/g, ""));
}

function identifier(value) {
  return /^[A-Za-z_][A-Za-z0-9_]*$/.test(value);
}

function isChildPidExpansion(value) {
  return value === "$!" || value === "${!}";
}

// ---------------------------------------------------------------------------
// Static analysis: find every signal send and every variable binding.

function newAnalysis() {
  return { sends: [], candidates: new Set(), disqualified: new Set(), unclassifiable: false, unprovable: false };
}

function recordAssignment(analysis, word) {
  const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
  if (match && !word.subs.length && isChildPidExpansion(match[2])) analysis.candidates.add(match[1]);
}

function childPidVariables(command, { candidates, disqualified }) {
  return new Set([...candidates].filter((name) => {
    if (disqualified.has(name)) return false;
    const assignments = [...command.matchAll(new RegExp(name + "\\+?=", "g"))];
    return assignments.length > 0 && assignments.every((match) => match[0] === name + "=" &&
      /^(?:"\$(?:!|\{!\})"|'\$(?:!|\{!\})'|\$(?:!|\{!\}))(?=$|[\s;&|()<>])/.test(command.slice(match.index + match[0].length)));
  }));
}

function stripReservedPrefixes(tokens) {
  let index = 0;
  while (index < tokens.length && tokens[index].type === "word" && !tokens[index].quoted && RESERVED_PREFIXES.has(tokens[index].value)) index += 1;
  return tokens.slice(index);
}

function skipWrapperOptions(words, index, takesArgument) {
  let next = index;
  while (words[next] && words[next].value.startsWith("-") && words[next].value !== "-") {
    const value = words[next].value;
    if (value === "--") return next + 1;
    next += takesArgument.has(value) ? 2 : 1;
  }
  return next;
}

// Follow wrappers to the command that actually runs.
function resolveCommand(tokens) {
  let position = commandPosition(tokens);
  let viaStdin = false;
  const wrapperPayloads = [];
  for (let hops = 0; hops < 16; hops += 1) {
    wrapperPayloads.push(...position.wrapperPayloads);
    const command = position.command;
    if (!command) break;
    const name = commandName(command.value);
    if (!Object.hasOwn(EXTRA_WRAPPERS, name)) {
      return { position, name, args: position.words.slice(position.index + 1), viaStdin, wrapperPayloads };
    }
    if (name === "xargs") viaStdin = true;
    const next = skipWrapperOptions(position.words, position.index + 1, EXTRA_WRAPPERS[name]);
    position = commandPosition(position.words.slice(next));
  }
  return { position, name: "", args: [], viaStdin, wrapperPayloads };
}

function shellPayload(name, args) {
  if (!SHELLS.has(name)) return { kind: "none" };
  let command = false;
  let stdin = false;
  let i = 0;
  for (; i < args.length; i += 1) {
    const word = args[i];
    if (command && (!word.literal || word.subs.length || !/^[-+]/.test(word.value))) break;
    if (!word.literal || word.subs.length || word.unquotedExpansion) return { kind: "unresolved" };
    const value = word.value;
    if (value === "--" || value === "-") {
      i += 1;
      break;
    }
    if (!/^[-+]/.test(value)) break;
    if (value.startsWith("--")) {
      if (["--rcfile", "--init-file"].includes(value)) {
        if (!args[++i]?.literal || args[i].subs.length) return { kind: "unresolved" };
      } else if (!["--noprofile", "--norc", "--posix", "--restricted", "--verbose", "--login"].includes(value)) {
        return { kind: "unresolved" };
      }
      continue;
    }
    for (let offset = 1; offset < value.length; offset += 1) {
      const flag = value[offset];
      if (flag === "o" || flag === "O") {
        if (offset !== value.length - 1 || !args[++i]?.literal || args[i].subs.length) return { kind: "unresolved" };
      } else if (flag === "c" && value[0] === "-") {
        command = true;
      } else if (flag === "s" && value[0] === "-") {
        stdin = true;
      } else if (!"abefhiklmnprtuvxBCEHPT".includes(flag)) {
        return { kind: "unresolved" };
      }
    }
  }
  if (command) return args[i] ? { kind: "command", word: args[i] } : { kind: "unresolved" };
  return { kind: stdin || i === args.length ? "stdin" : "script" };
}

function recordSignalSend(analysis, name, args, source) {
  if (name === "kill") {
    analysis.sends.push({ tool: "kill", args, source });
    return;
  }
  if (BY_NAME_TOOLS.has(name)) {
    if (args.length > 0 && args.every((word) => BY_NAME_HARMLESS_ARGS.has(word.value))) return;
    analysis.sends.push({ tool: name, byName: true });
    return;
  }
  if (name === "fuser" && args.some((word) => word.value === "--kill" || /^-[A-Za-z]*k[A-Za-z]*$/.test(word.value))) {
    analysis.sends.push({ tool: "fuser", byName: true });
  }
}

function analyzePayload(words, analysis, depth) {
  const text = words.map((word) => [word.value, ...word.subs.map((sub) => sub.content)].join(" ")).join(" ");
  if (words.some((word) => !word.literal || word.subs.length || word.unquotedExpansion)) {
    if (mentionsSignalTool(text)) analysis.unprovable = true;
    return;
  }
  analyzeProgram(words.map((word) => word.value).join(" "), analysis, depth + 1);
}

function nodeMentionsSignal(tokens) {
  return tokens.some((token) => mentionsSignalTool([
    token.value || "", token.content || "", token.heredoc || "",
    ...(token.subs || []).map((sub) => sub.content),
  ].join(" ")));
}

function analyzeSplitPayload(payload, analysis, depth, source, tokens) {
  if (!payload.literal || payload.subs.length || payload.unquotedExpansion ||
      !/^[A-Za-z0-9_./=+: \t-]*$/.test(payload.value)) {
    if (nodeMentionsSignal(tokens)) analysis.unprovable = true;
    return;
  }
  const split = new Lexer(payload.value).tokenize();
  const redirections = [];
  for (let i = 0; i < tokens.length; i += 1) {
    if (tokens[i].type !== "redir") continue;
    redirections.push(tokens[i]);
    if (!tokens[i].inlineTarget && tokens[i + 1]?.type === "word") redirections.push(tokens[++i]);
  }
  analyzeNode([...split.tokens, ...payload.trailingWords, ...redirections], analysis, depth + 1, source);
}

function recordFindExec(analysis, args, depth) {
  for (let i = 0; i < args.length; i += 1) {
    if (!FIND_EXEC_ACTIONS.has(args[i].value)) continue;
    const end = args.findIndex((word, index) => index > i + 1 && (word.value === ";" || word.value === "+"));
    analyzeNode(args.slice(i + 1, end === -1 ? undefined : end), analysis, depth + 1, "find");
    if (end === -1) break;
    i = end;
  }
}

function analyzeProgram(text, analysis, depth = 0) {
  if (depth > 12) {
    if (mentionsSignalTool(text)) analysis.unclassifiable = true;
    return;
  }
  const lexed = new Lexer(text).tokenize();
  if (lexed.error) {
    if (mentionsSignalTool(text)) analysis.unclassifiable = true;
    return;
  }
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) analyzeNode(node, analysis, depth);
}

function analyzeNode(rawTokens, analysis, depth, source = "argv") {
  if (depth > 12) {
    analysis.unclassifiable = true;
    return;
  }
  const tokens = stripReservedPrefixes(rawTokens);
  const resolved = resolveCommand(tokens);
  const { position, name, args, viaStdin } = resolved;
  const shell = shellPayload(name, args);
  // Nested programs run wherever they appear, so recurse into every one.
  for (const token of rawTokens) {
    if (typeof token.heredoc === "string" && !token.heredocQuoted && !(shell.kind === "stdin" && token.fd === 0 && !resolved.wrapperPayloads.length)) {
      const lexer = new Lexer(token.heredoc);
      const word = { value: "", subs: [], literal: true };
      lexer.readDoubleQuoted(word, true);
      if (lexer.error && mentionsSignalTool(token.heredoc)) analysis.unclassifiable = true;
      for (const sub of word.subs) analyzeProgram(sub.content, analysis, depth + 1);
    }
    if (token.type === "group") analyzeProgram(token.content, analysis, depth + 1);
    if (token.type === "word") {
      for (const substitution of token.subs) analyzeProgram(substitution.content, analysis, depth + 1);
    }
  }

  const head = tokens.find((token) => token.type === "word");
  if (head && !head.quoted && (head.value === "for" || head.value === "select")) {
    const variable = tokens.filter((token) => token.type === "word")[1];
    if (variable && identifier(variable.value)) analysis.disqualified.add(variable.value);
    return;
  }

  for (const word of position.words.slice(0, position.prefixAssignments)) recordAssignment(analysis, word);
  if (resolved.wrapperPayloads.length) {
    analyzeSplitPayload(resolved.wrapperPayloads[0], analysis, depth, viaStdin ? "stdin" : source, rawTokens);
    return;
  }
  if (!name) return;

  if (name === "read") analysis.disqualified.add("REPLY");
  if (name === "mapfile" || name === "readarray") analysis.disqualified.add("MAPFILE");
  if (["declare", "local", "export", "typeset", "readonly", "read", "mapfile", "readarray", "getopts", "let"].includes(name)) {
    for (const word of args) {
      const bound = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)/);
      if (bound) analysis.disqualified.add(bound[1]);
    }
  }
  if (name === "printf") {
    for (let i = 0; i < args.length; i += 1) {
      const value = args[i].value;
      const target = value === "-v" ? args[i + 1]?.value : (value.startsWith("-v") ? value.slice(2) : "");
      const bound = target?.match(/^([A-Za-z_][A-Za-z0-9_]*)/);
      if (bound) analysis.disqualified.add(bound[1]);
    }
  }

  if (shell.kind === "unresolved" && nodeMentionsSignal(rawTokens)) analysis.unprovable = true;
  if (shell.kind === "command") analyzePayload([shell.word], analysis, depth);
  if (shell.kind === "stdin") {
    for (let i = 0; i < tokens.length; i += 1) {
      const token = tokens[i];
      if (token.type !== "redir" || token.fd !== 0) continue;
      if (typeof token.heredoc === "string") analyzeProgram(token.heredoc, analysis, depth + 1);
      if (token.value === "<<<" && tokens[i + 1]?.type === "word") analyzePayload([tokens[i + 1]], analysis, depth);
    }
  }
  if (name === "eval" && args.length > 0) analyzePayload(args, analysis, depth);
  if (name === "trap") {
    const payload = args.find((word) => !word.value.startsWith("-"));
    if (payload) analyzePayload([payload], analysis, depth);
  }
  if (name === "find") recordFindExec(analysis, args, depth);

  recordSignalSend(analysis, name, args, viaStdin ? "stdin" : source);
}

// ---------------------------------------------------------------------------
// Static classification of kill arguments.

// Parse kill's options the way bash's builtin and util-linux kill do: only the
// first dash word names the signal, so a later -N is a process-group operand.
function parseKillArguments(args) {
  let signal = null;
  const scheduled = args.some((word) => word.value === "--timeout" || word.value.startsWith("--timeout="));
  for (let i = 0; i < args.length; i += 1) {
    const word = args[i];
    if (word.subs.length > 0 || !word.value.startsWith("-") || word.value === "-") return { listing: false, signal, scheduled, operands: args.slice(i) };
    const value = word.value;
    if (value === "--") return { listing: false, signal, scheduled, operands: args.slice(i + 1) };
    if (["-l", "-L", "--list", "--table"].includes(value) || value.startsWith("--list=")) return { listing: true, signal, scheduled, operands: [] };
    if (value === "-s" || value === "-n" || value === "--signal") {
      signal = args[i + 1]?.value ?? "";
      i += 1;
      continue;
    }
    if (value.startsWith("--signal=")) {
      signal = value.slice("--signal=".length);
      continue;
    }
    if (value === "-q" || value === "--queue") {
      i += 1;
      continue;
    }
    if (value === "--timeout" || value.startsWith("--timeout=")) {
      i += value === "--timeout" ? 2 : 1;
      continue;
    }
    if (["-a", "--all", "-p", "--pid", "--verbose", "-r", "--require-handler"].includes(value)) continue;
    if (signal === null) {
      signal = value.slice(1);
      continue;
    }
    return { listing: false, signal, scheduled, operands: args.slice(i) };
  }
  return { listing: false, signal, scheduled, operands: [] };
}

// Lex a substitution body that reads a PID file: `cat <path>` or `< <path>`.
function pidFilePath(content) {
  const lexed = new Lexer(content).tokenize();
  if (lexed.error) return null;
  const tokens = lexed.tokens.filter((token) => !(token.type === "op" && token.value === "newline"));
  const plain = (token) => token?.type === "word" && token.literal && token.subs.length === 0 && !token.unquotedExpansion;
  if (tokens.length !== 2 || !plain(tokens[1])) return null;
  const reader = tokens[0];
  if (!(reader.type === "word" && !reader.quoted && reader.value === "cat") &&
      !(reader.type === "redir" && reader.value === "<")) return null;
  const file = tokens[1];
  if (path.isAbsolute(file.value)) return file.value;
  if (!file.quoted && !file.escaped && file.value.startsWith("~/")) return path.join(os.homedir(), file.value.slice(2));
  return null;
}

function classifyOperand(word, childPidVars) {
  if (word.subs.length === 0) {
    const value = word.value;
    if (word.literal) {
      if (/^\d+$/.test(value)) return Number(value) === 0 ? { kind: "broadcast" } : { kind: "pid", pid: Number(value) };
      if (/^-\d+$/.test(value)) return Number(value.slice(1)) <= 1 ? { kind: "broadcast" } : { kind: "group", pgid: Number(value.slice(1)) };
      if (value.startsWith("%")) return { kind: "own" };
      return { kind: "unprovable" };
    }
    if (isChildPidExpansion(value)) return { kind: "own" };
    const variable = value.match(/^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))$/);
    if (variable && childPidVars.has(variable[1] || variable[2])) return { kind: "own" };
    return { kind: "unprovable" };
  }
  if (word.subs.length === 1 && word.value === "" && word.subs[0].kind === "command") {
    const content = word.subs[0].content.trim();
    if (/^jobs(?=(?:\s+-[prs]+)*\s+-[prs]*p)(?:\s+-[prs]+)+(?:\s+%[^\s;&|()<>$`]+)*$/.test(content)) return { kind: "own" };
    const file = pidFilePath(content);
    if (file !== null) return { kind: "pidfile", path: file };
  }
  return { kind: "unprovable" };
}

// ---------------------------------------------------------------------------
// Dynamic verification against the live process table.

function processTable() {
  const output = execFileSync("ps", ["-A", "-o", "pid=,ppid=,pgid="], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
    timeout: 10000,
    maxBuffer: 64 * 1024 * 1024,
  });
  const table = new Map();
  for (const line of output.split("\n")) {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)$/);
    if (match) table.set(Number(match[1]), { ppid: Number(match[2]), pgid: Number(match[3]) });
  }
  if (!table.has(process.pid)) throw new Error("process table does not list this policy process");
  return table;
}

function carriesScope(pid, token) {
  let raw;
  try {
    raw = readFileSync(`/proc/${pid}/environ`);
  } catch {
    return false;
  }
  return raw.toString("utf8").split("\0").includes(`${SCOPE_VARIABLE}=${token}`);
}

function ancestry(table, pid) {
  const chain = [];
  const seen = new Set();
  let current = pid;
  while (table.has(current) && !seen.has(current)) {
    chain.push(current);
    seen.add(current);
    const parent = table.get(current).ppid;
    if (parent === 0 || parent === current) break;
    current = parent;
  }
  return chain;
}

// The session root is the topmost process of the contiguous run of ancestors
// that carry this session's marker, starting from the first carrier above this
// policy process. fm-spawn sets the marker on the agent launch only, so the
// agent's own parent shell does not carry it and the run stops at the agent.
function sessionRoot(chain, token) {
  let index = chain.findIndex((pid) => carriesScope(pid, token));
  if (index === -1) return null;
  while (index + 1 < chain.length && carriesScope(chain[index + 1], token)) index += 1;
  return chain[index];
}

function makeVerifier(token) {
  const table = processTable();
  const chain = ancestry(table, process.pid);
  const ancestors = new Set(chain);
  const root = SCOPE_PATTERN.test(token) ? sessionRoot(chain, token) : null;
  const verify = (pid) => {
    if (!table.has(pid)) return `PID ${pid} does not exist`;
    if (pid === root) return `PID ${pid} is this session's own agent process`;
    if (ancestors.has(pid)) return `PID ${pid} is an ancestor of this session (its shell, the terminal server, or the service manager above it)`;
    const seen = new Set();
    let current = pid;
    while (table.has(current) && !seen.has(current)) {
      seen.add(current);
      const parent = table.get(current).ppid;
      if (parent === root) return null;
      if (parent <= 1) break;
      current = parent;
    }
    if (carriesScope(pid, token)) return null;
    return `PID ${pid} is not a descendant of this session's agent process and does not carry this session's process-scope marker`;
  };
  const verifyGroup = (pgid) => {
    const members = [...table].filter(([, info]) => info.pgid === pgid).map(([pid]) => pid);
    if (members.length === 0) return `process group ${pgid} does not exist`;
    for (const member of members) {
      const problem = verify(member);
      if (problem) return `process group ${pgid} includes a process outside this session: ${problem}`;
    }
    return null;
  };
  return { root, verify, verifyGroup };
}

function readPidFile(resolved) {
  let stat;
  try {
    stat = statSync(resolved);
  } catch {
    return { problem: `PID file ${resolved} does not exist yet; within the command that starts the job, use $! instead` };
  }
  if (!stat.isFile() || stat.size > 4096) return { problem: `PID file ${resolved} is not a small regular file` };
  const words = readFileSync(resolved, "utf8").split(/\s+/).filter(Boolean);
  if (words.length === 0 || !words.every((value) => /^\d+$/.test(value))) return { problem: `PID file ${resolved} does not hold only PIDs` };
  return { pids: words.map(Number) };
}

// ---------------------------------------------------------------------------

function deny(code, detail = "") {
  const reason = detail ? `${detail}. ${REASONS[code]}` : REASONS[code];
  return { decision: "deny", code, reason: reason.replace(/[\t\r\n]+/g, " ") };
}

function decision(command, scope = "") {
  const analysis = newAnalysis();
  analyzeProgram(command, analysis);
  if (analysis.unprovable) return deny("signal-unprovable-target");
  if (analysis.unclassifiable) return deny("signal-unclassifiable");
  if (analysis.sends.length === 0) return { decision: "allow" };

  const childPidVars = childPidVariables(command, analysis);
  const checks = [];
  let staticDeny = null;
  for (const send of analysis.sends) {
    if (send.byName) {
      staticDeny ||= deny("signal-by-name");
      continue;
    }
    const parsed = parseKillArguments(send.args);
    if (parsed.listing || (parsed.signal === "0" && !parsed.scheduled)) continue;
    if (send.source !== "argv") {
      staticDeny ||= deny("signal-unprovable-target");
      continue;
    }
    for (const operand of parsed.operands) {
      const classified = classifyOperand(operand, childPidVars);
      if (classified.kind === "broadcast") staticDeny ||= deny("signal-broadcast");
      else if (classified.kind === "unprovable") staticDeny ||= deny("signal-unprovable-target");
      else if (classified.kind === "pidfile" && command.split(path.basename(classified.path)).length !== 2) staticDeny ||= deny("signal-unprovable-target");
      else if (classified.kind !== "own") checks.push(classified);
    }
  }
  if (staticDeny) return staticDeny;
  if (checks.length === 0) return { decision: "allow" };

  let verifier;
  try {
    verifier = makeVerifier(scope);
  } catch {
    return deny("signal-unverifiable");
  }
  if (verifier.root === null) return deny("signal-no-scope");
  for (const check of checks) {
    let problem = null;
    if (check.kind === "pid") problem = verifier.verify(check.pid);
    if (check.kind === "group") problem = verifier.verifyGroup(check.pgid);
    if (check.kind === "pidfile") {
      const file = readPidFile(check.path);
      problem = file.problem || null;
      for (const pid of file.pids || []) problem ||= verifier.verify(pid);
    }
    if (problem) return deny("signal-outside-session", problem);
  }
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", scope: "", cwd: "" };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--scope" || name === "--cwd") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      result[name.slice(2)] = argv[i + 1];
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = args.command ? decision(args.command, args.scope) : { decision: "allow" };
    if (result.decision === "allow") {
      process.stdout.write("allow\n");
    } else {
      process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
