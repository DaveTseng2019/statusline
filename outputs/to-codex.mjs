#!/usr/bin/env node
// Claude Code session -> Codex thread. Prints `codex resume <id>`.
// Usage: node to-codex.mjs [--source <claude.jsonl>]
import { spawn } from "node:child_process";
import readline from "node:readline";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CODEX_HOME = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const PROJECTS = path.join(os.homedir(), ".claude", "projects");

function resolveCodexBin() {
  if (process.env.CODEX_BIN) return process.env.CODEX_BIN;
  const root = path.join(process.env.LOCALAPPDATA || "", "OpenAI", "Codex", "bin");
  if (!fs.existsSync(root)) return "codex";
  const hit = fs
    .readdirSync(root)
    .map((d) => path.join(root, d, "codex.exe"))
    .filter((p) => fs.existsSync(p))
    .map((p) => ({ p, m: fs.statSync(p).mtimeMs }))
    .sort((a, b) => b.m - a.m)[0];
  return hit ? hit.p : "codex";
}

function newestJsonl(dir) {
  if (!fs.existsSync(dir)) return null;
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => path.join(dir, f))
    .map((p) => ({ p, m: fs.statSync(p).mtimeMs }))
    .sort((a, b) => b.m - a.m)[0]?.p ?? null;
}

function resolveTranscript(explicit) {
  if (explicit) return fs.realpathSync(explicit);
  const cwd = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const slug = cwd.replace(/[^a-zA-Z0-9]/g, "-");
  const own = newestJsonl(path.join(PROJECTS, slug));
  if (own) return fs.realpathSync(own);
  // fallback: newest transcript across all projects
  const all = fs
    .readdirSync(PROJECTS)
    .map((d) => newestJsonl(path.join(PROJECTS, d)))
    .filter(Boolean)
    .map((p) => ({ p, m: fs.statSync(p).mtimeMs }))
    .sort((a, b) => b.m - a.m)[0];
  if (!all) throw new Error(`No Claude transcript found under ${PROJECTS}`);
  return fs.realpathSync(all.p);
}

// codex records paths with the Windows \\?\ extended prefix; compare normalized
const normPath = (p) => path.resolve(String(p).replace(/^\\\\\?\\/, "")).toLowerCase();

function importedThreadId(sourcePath) {
  const ledger = path.join(CODEX_HOME, "external_agent_session_imports.json");
  if (!fs.existsSync(ledger)) return null;
  const records = JSON.parse(fs.readFileSync(ledger, "utf8"))?.records ?? [];
  const want = normPath(sourcePath);
  return records.filter((r) => r?.imported_thread_id && normPath(r.source_path) === want).at(-1)?.imported_thread_id ?? null;
}

async function main() {
  const i = process.argv.indexOf("--source");
  const source = resolveTranscript(i > -1 ? process.argv[i + 1] : null);
  const cwd = process.env.CLAUDE_PROJECT_DIR || process.cwd();

  const proc = spawn(resolveCodexBin(), ["app-server"], { cwd, stdio: ["pipe", "pipe", "pipe"], windowsHide: true });
  let stderr = "";
  proc.stderr.setEncoding("utf8");
  proc.stderr.on("data", (c) => (stderr += c));

  let nextId = 1;
  const pending = new Map();
  let onImportDone = null;
  readline.createInterface({ input: proc.stdout }).on("line", (line) => {
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id != null && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    } else if (msg.method === "externalAgentConfig/import/completed") {
      onImportDone?.();
    }
  });
  const send = (o) => proc.stdin.write(JSON.stringify(o) + "\n");
  const request = (method, params) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      send({ jsonrpc: "2.0", id, method, params });
    });

  await request("initialize", {
    clientInfo: { title: "to-codex", name: "Claude Code", version: "1.0.0" },
    capabilities: { experimentalApi: false, requestAttestation: false }
  });
  send({ jsonrpc: "2.0", method: "initialized", params: {} });

  const done = new Promise((resolve, reject) => {
    onImportDone = resolve;
    setTimeout(() => reject(new Error("Timed out waiting for import.")), 120_000);
  });
  await request("externalAgentConfig/import", {
    migrationItems: [
      {
        itemType: "SESSIONS",
        description: `Transfer Claude session ${path.basename(source)}`,
        cwd: null,
        details: { plugins: [], sessions: [{ path: source, cwd, title: null }], mcpServers: [], hooks: [], subagents: [], commands: [] }
      }
    ]
  });
  await done;
  proc.stdin.end();
  proc.kill();

  const threadId = importedThreadId(source);
  if (!threadId) throw new Error(`Import reported done but no thread recorded.${stderr ? "\n" + stderr : ""}`);
  console.log(`Imported: ${path.basename(source)}\ncodex resume ${threadId}`);
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
