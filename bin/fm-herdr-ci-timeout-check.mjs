#!/usr/bin/env node
// Verify the required Herdr CI lane's job and family-run step timeouts.
// Usage: fm-herdr-ci-timeout-check.mjs [.github/workflows/ci.yml]
//
// This parser intentionally builds the workflow's mapping and sequence structure.
// A text search is not sufficient because an upload-artifact `with.name` can have
// the same scalar value as a step's `name` without representing that step.
// The supported YAML subset covers the repository workflow and fails closed on
// unsupported syntax instead of guessing at a structure.

import { readFileSync } from "node:fs";

const EXPECTED_JOB_TIMEOUT = "75";
const EXPECTED_STEP_TIMEOUT = "20";
const FAMILY_STEP_NAME = "Run real-Herdr family (serial, required)";

function parseError(line, message) {
  const suffix = line ? ` at line ${line.number}` : "";
  throw new Error(`invalid workflow YAML${suffix}: ${message}`);
}

function scalar(value, line) {
  const text = value.trim();
  if (text.startsWith("&") || text.startsWith("*")) {
    parseError(line, "anchors and aliases are unsupported");
  }
  if (text.startsWith("'") || text.startsWith('"')) {
    const quote = text[0];
    if (!text.endsWith(quote) || text.length < 2) {
      parseError(line, "multi-line quoted scalars are unsupported");
    }
    const inner = text.slice(1, -1);
    if (quote === "'") return inner.replaceAll("''", "'");
    try {
      return JSON.parse(text);
    } catch {
      parseError(line, "invalid double-quoted scalar");
    }
  }
  return text;
}

function mappingEntry(content, line) {
  const match = /^([A-Za-z0-9_.-]+):(?:[ ]+(.*))?$/.exec(content);
  if (!match) parseError(line, "expected a simple mapping key");
  return { key: match[1], value: match[2] ?? "" };
}

function workflowLines(source) {
  const lines = [];
  source.split(/\r?\n/).forEach((raw, index) => {
    if (/^\s*$/.test(raw) || /^\s*#/.test(raw)) return;
    if (/^\s*(?:---|\.\.\.)\s*$/.test(raw)) {
      parseError({ number: index + 1 }, "multiple-document markers are unsupported");
    }
    const indentText = raw.match(/^[ ]*/)[0];
    if (raw[indentText.length] === "\t") {
      parseError({ number: index + 1 }, "tab indentation is unsupported");
    }
    lines.push({ number: index + 1, indent: indentText.length, content: raw.slice(indentText.length) });
  });
  return lines;
}

function parseWorkflowYaml(source) {
  const lines = workflowLines(source);
  let cursor = 0;

  function skipBlockScalar(parentIndent) {
    while (cursor < lines.length && lines[cursor].indent > parentIndent) cursor += 1;
    return "";
  }

  function parseValue(value, line) {
    if (/^[|>][+-]?$/.test(value)) {
      cursor += 1;
      return skipBlockScalar(line.indent);
    }
    cursor += 1;
    return scalar(value, line);
  }

  function parseNestedValue(line) {
    cursor += 1;
    if (cursor >= lines.length || lines[cursor].indent <= line.indent) return null;
    return parseBlock(lines[cursor].indent);
  }

  function parseMap(indent) {
    const result = {};
    while (cursor < lines.length && lines[cursor].indent === indent) {
      const line = lines[cursor];
      if (line.content.startsWith("-")) break;
      const entry = mappingEntry(line.content, line);
      if (Object.hasOwn(result, entry.key)) parseError(line, `duplicate key ${entry.key}`);
      result[entry.key] = entry.value === "" ? parseNestedValue(line) : parseValue(entry.value, line);
    }
    return result;
  }

  function parseSequence(indent) {
    const result = [];
    while (cursor < lines.length && lines[cursor].indent === indent) {
      const line = lines[cursor];
      if (!/^-(?: |$)/.test(line.content)) break;
      const inline = line.content.slice(1).trimStart();
      if (inline === "") {
        result.push(parseNestedValue(line));
        continue;
      }
      if (!/^[A-Za-z0-9_.-]+:(?: |$)/.test(inline)) {
        cursor += 1;
        result.push(scalar(inline, line));
        continue;
      }
      lines[cursor] = { ...line, indent: indent + 2, content: inline };
      result.push(parseBlock(indent + 2));
    }
    return result;
  }

  function parseBlock(indent) {
    const line = lines[cursor];
    if (!line || line.indent !== indent) parseError(line, `expected indentation ${indent}`);
    const value = /^-(?: |$)/.test(line.content) ? parseSequence(indent) : parseMap(indent);
    if (cursor < lines.length && lines[cursor].indent > indent) {
      parseError(lines[cursor], `unexpected indentation below line ${line.number}`);
    }
    return value;
  }

  if (lines.length === 0) throw new Error("invalid workflow YAML: document is empty");
  const document = parseBlock(lines[0].indent);
  if (cursor !== lines.length) parseError(lines[cursor], "could not consume document");
  return document;
}

function requireMap(value, label) {
  if (!value || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`${label} must be a mapping`);
  }
  return value;
}

function verifyWorkflow(document) {
  const jobs = requireMap(document.jobs, "jobs");
  const job = requireMap(jobs["tests-herdr"], "jobs.tests-herdr");
  if (job["timeout-minutes"] !== EXPECTED_JOB_TIMEOUT) {
    throw new Error(`tests-herdr job backstop must stay 75 minutes, got ${job["timeout-minutes"] ?? "missing"}`);
  }
  if (!Array.isArray(job.steps)) throw new Error("jobs.tests-herdr.steps must be a sequence");
  const step = job.steps.find((candidate) => {
    return candidate && !Array.isArray(candidate) && typeof candidate === "object" && candidate.name === FAMILY_STEP_NAME;
  });
  if (!step) throw new Error(`missing step named ${FAMILY_STEP_NAME}`);
  if (step["timeout-minutes"] !== EXPECTED_STEP_TIMEOUT) {
    throw new Error(`family-run step timeout must be 20 minutes, got ${step["timeout-minutes"] ?? "missing"}`);
  }
  if (Number(step["timeout-minutes"]) >= Number(job["timeout-minutes"])) {
    throw new Error("family-run step timeout must be below the job backstop");
  }
}

const workflowPath = process.argv[2] ?? ".github/workflows/ci.yml";
try {
  const document = parseWorkflowYaml(readFileSync(workflowPath, "utf8"));
  verifyWorkflow(document);
} catch (error) {
  process.stderr.write(`fm-herdr-ci-timeout-check: ${error.message}\n`);
  process.exitCode = 1;
}
