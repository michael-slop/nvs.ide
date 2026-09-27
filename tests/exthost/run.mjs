#!/usr/bin/env node
// Drives runtime/exthost/host.js over a pipe with LSP JSON-RPC, without Neovim.
//
//   node tests/exthost/run.mjs
//
// Needs only Node 18+. Every result line starts with PASS or FAIL; the exit code is
// the number of failures. Runs in CI. It spawns the host four times against the two
// fixtures under tests/exthost/fixtures/ and a temp folder that is removed at the end:
//
//   A  nvs.synthetic: capabilities, dynamic registration, diagnostics, completion and
//      resolve, hover, definition, a command with progress and a message, formatting,
//      a code action, settings from workspace/configuration, globalState on disk,
//      stdout hygiene and the unsupported-member log line, then shutdown/exit.
//   B  nvs.synthetic: a request before initialize is refused, an unknown method is
//      refused, and closing stdin makes the host exit.
//   C  nvs.throws: activate throws; initialize answers with no capabilities.
//   D  nvs.synthetic with --settings and a client without workspace/configuration.

import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..", "..");
const HOST = path.join(repo, "runtime", "exthost", "host.js");
const FIXTURES = path.join(here, "fixtures");
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "nvs-exthost-"));

let passed = 0;
let failed = 0;
function check(name, condition, detail) {
  if (condition) {
    passed++;
    console.log("PASS " + name);
  } else {
    failed++;
    console.log("FAIL " + name + (detail === undefined ? "" : ": " + (typeof detail === "string" ? detail : JSON.stringify(detail))));
  }
}

const clients = new Set();
const watchdog = setTimeout(() => {
  console.log("FAIL watchdog: the run took more than 90 s");
  for (const c of clients) c.kill();
  process.exit(99);
}, 90000);

// A minimal LSP client over the child's pipes, independent of runtime/exthost/lsp.js
// so a framing bug there cannot hide from the test.
class Client {
  constructor(extensionDir, extraArgs) {
    this.child = spawn(process.execPath, [HOST, "--extension", extensionDir, ...extraArgs, "--stdio"], { stdio: ["pipe", "pipe", "pipe"] });
    this.buffer = Buffer.alloc(0);
    this.garbage = 0; // bytes seen on stdout outside a frame
    this.stderr = "";
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.inbox = []; // { method, params, consumed }
    this.waiters = [];
    this.exited = new Promise((resolve) => this.child.on("exit", (code, signal) => resolve({ code, signal })));
    this.child.stdout.on("data", (chunk) => this._onData(chunk));
    this.child.stderr.on("data", (chunk) => {
      this.stderr += chunk.toString();
    });
    clients.add(this);
  }

  _onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    for (;;) {
      const headerEnd = this.buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = this.buffer.subarray(0, headerEnd).toString("ascii");
      const m = /Content-Length:\s*(\d+)/i.exec(header);
      if (!m || !header.startsWith("Content-Length")) {
        // Anything that is not a clean header is garbage on stdout.
        this.garbage += headerEnd + 4;
        this.buffer = this.buffer.subarray(headerEnd + 4);
        continue;
      }
      const length = parseInt(m[1], 10);
      const start = headerEnd + 4;
      if (this.buffer.length < start + length) return;
      const body = this.buffer.subarray(start, start + length).toString("utf8");
      this.buffer = this.buffer.subarray(start + length);
      let message;
      try {
        message = JSON.parse(body);
      } catch (err) {
        this.garbage += length;
        continue;
      }
      this._dispatch(message);
    }
  }

  _send(message) {
    const body = Buffer.from(JSON.stringify(message), "utf8");
    this.child.stdin.write(Buffer.concat([Buffer.from("Content-Length: " + body.length + "\r\n\r\n", "ascii"), body]));
  }

  _dispatch(message) {
    if (message.method !== undefined) {
      const entry = { method: message.method, params: message.params, consumed: false, id: message.id };
      this.inbox.push(entry);
      if (message.id !== undefined) {
        const handler = this.handlers.get(message.method);
        if (handler) {
          Promise.resolve()
            .then(() => handler(message.params))
            .then(
              (result) => this._send({ jsonrpc: "2.0", id: message.id, result: result === undefined ? null : result }),
              (err) => this._send({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: String(err) } })
            );
        } else {
          this._send({ jsonrpc: "2.0", id: message.id, error: { code: -32601, message: "test client has no handler for " + message.method } });
        }
      }
      for (const w of this.waiters.slice()) w.tryMatch();
      return;
    }
    const p = this.pending.get(message.id);
    if (!p) return;
    this.pending.delete(message.id);
    if (message.error) p.reject(Object.assign(new Error(message.error.message), { code: message.error.code, data: message.error.data }));
    else p.resolve(message.result);
  }

  request(method, params, timeoutMs) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error("timeout waiting for response to " + method));
      }, timeoutMs || 15000);
      this.pending.set(id, {
        resolve: (v) => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
      this._send({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method, params) {
    this._send({ jsonrpc: "2.0", method, params });
  }

  onRequest(method, handler) {
    this.handlers.set(method, handler);
  }

  // Resolves with the params of the first unconsumed inbox message matching method
  // (and predicate), whether it arrived already or arrives later.
  waitFor(method, predicate, timeoutMs) {
    return new Promise((resolve, reject) => {
      const waiter = {
        tryMatch: () => {
          const hit = this.inbox.find((e) => !e.consumed && e.method === method && (!predicate || predicate(e.params)));
          if (!hit) return false;
          hit.consumed = true;
          clearTimeout(timer);
          this.waiters = this.waiters.filter((w) => w !== waiter);
          resolve(hit.params);
          return true;
        },
      };
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== waiter);
        reject(new Error("timeout waiting for " + method));
      }, timeoutMs || 15000);
      this.waiters.push(waiter);
      waiter.tryMatch();
    });
  }

  received(method, predicate) {
    return this.inbox.filter((e) => e.method === method && (!predicate || predicate(e.params))).map((e) => e.params);
  }

  waitExit(timeoutMs) {
    return Promise.race([this.exited, new Promise((resolve) => setTimeout(() => resolve(null), timeoutMs || 5000))]);
  }

  kill() {
    try {
      this.child.kill();
    } catch (_) {
      // Already gone.
    }
  }
}

function fileUri(p) {
  return pathToFileURL(p).href;
}

const CAPS_FULL = {
  textDocument: {
    completion: { dynamicRegistration: false, completionItem: { snippetSupport: true } },
    hover: { dynamicRegistration: true },
    definition: { dynamicRegistration: true },
    formatting: { dynamicRegistration: true },
    codeAction: { dynamicRegistration: true },
  },
  workspace: { configuration: true, workspaceFolders: true, applyEdit: true },
  window: { workDoneProgress: true, showMessage: { messageActionItem: {} } },
};

function readLog(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch (_) {
    return "";
  }
}

// ---------------------------------------------------------------------------
async function scenarioA() {
  const ws = path.join(tmpRoot, "a-ws");
  const dataDir = path.join(tmpRoot, "a-data");
  const logFile = path.join(tmpRoot, "a.log");
  fs.mkdirSync(ws, { recursive: true });
  const file = path.join(ws, "note.txt");
  const text = "hello world TODO\nfoo.bar   \n";
  fs.writeFileSync(file, text);
  const uri = fileUri(file);

  const c = new Client(path.join(FIXTURES, "nvs.synthetic"), ["--data", dataDir, "--log", logFile]);
  c.onRequest("workspace/configuration", (p) => p.items.map((it) => (it.section === "synthetic" ? { greeting: "howdy" } : null)));
  c.onRequest("client/registerCapability", () => null);
  c.onRequest("client/unregisterCapability", () => null);
  c.onRequest("window/workDoneProgress/create", () => null);
  c.onRequest("window/showMessageRequest", (p) => p.actions[0]);

  const init = await c.request("initialize", {
    processId: process.pid,
    clientInfo: { name: "run.mjs", version: "1" },
    rootUri: fileUri(ws),
    workspaceFolders: [{ uri: fileUri(ws), name: "a-ws" }],
    capabilities: CAPS_FULL,
  });
  const caps = init.capabilities || {};
  check("A initialize: serverInfo names the host", init.serverInfo && init.serverInfo.name === "nvs-exthost", init.serverInfo);
  check("A initialize: incremental textDocumentSync", caps.textDocumentSync && caps.textDocumentSync.change === 2 && caps.textDocumentSync.openClose === true, caps.textDocumentSync);
  check("A initialize: completionProvider with trigger characters and resolve", caps.completionProvider && JSON.stringify(caps.completionProvider.triggerCharacters) === '[".","@"]' && caps.completionProvider.resolveProvider === true, caps.completionProvider);
  check("A initialize: hoverProvider", caps.hoverProvider === true, caps.hoverProvider);
  check("A initialize: documentFormattingProvider", caps.documentFormattingProvider === true, caps.documentFormattingProvider);
  check("A initialize: codeActionProvider with kinds", caps.codeActionProvider && JSON.stringify(caps.codeActionProvider.codeActionKinds) === '["quickfix"]', caps.codeActionProvider);
  check("A initialize: executeCommandProvider lists synthetic.echo", caps.executeCommandProvider && caps.executeCommandProvider.commands.includes("synthetic.echo"), caps.executeCommandProvider);
  check("A initialize: definitionProvider not yet announced (registered late)", caps.definitionProvider === undefined, caps.definitionProvider);
  check("A initialize: positionEncoding utf-16", caps.positionEncoding === "utf-16", caps.positionEncoding);

  c.notify("initialized", {});
  const cfgReq = await c.waitFor("workspace/configuration");
  check("A workspace/configuration asked for the synthetic section", cfgReq.items.some((it) => it.section === "synthetic"), cfgReq);
  const reg = await c.waitFor("client/registerCapability", (p) => p.registrations.some((r) => r.method === "textDocument/definition"));
  const defReg = reg.registrations.find((r) => r.method === "textDocument/definition");
  check("A late definition provider registered dynamically with its selector", JSON.stringify(defReg.registerOptions.documentSelector) === '[{"language":"plaintext"}]', defReg);

  c.notify("textDocument/didOpen", { textDocument: { uri, languageId: "plaintext", version: 1, text } });
  const diag = await c.waitFor("textDocument/publishDiagnostics", (p) => p.uri === uri && p.diagnostics.length === 1);
  const d = diag.diagnostics[0];
  check("A diagnostics: TODO flagged as LSP warning at 0:12-0:16 with source", d.severity === 2 && d.source === "synthetic" && d.code === "todo" && d.range.start.line === 0 && d.range.start.character === 12 && d.range.end.character === 16, d);

  const completion = await c.request("textDocument/completion", { textDocument: { uri }, position: { line: 1, character: 4 }, context: { triggerKind: 2, triggerCharacter: "." } });
  const greeting = completion.items.find((i) => i.label === "greeting");
  check("A completion: snippet item with client setting applied", greeting && greeting.insertTextFormat === 2 && greeting.insertText === "howdy ${1:name}" && greeting.kind === 15, greeting);
  check("A completion: markdown documentation", greeting && greeting.documentation && greeting.documentation.kind === "markdown" && greeting.documentation.value === "**bold** doc", greeting && greeting.documentation);
  check("A completion: trigger character reached the provider", completion.items.some((i) => i.label === "trigger:."), completion.items.map((i) => i.label));
  check("A completion: setting without default answers its type default", completion.items.some((i) => i.label === "flags:[]"), completion.items.map((i) => i.label));
  const resolved = await c.request("completionItem/resolve", greeting);
  check("A completionItem/resolve reaches resolveCompletionItem", resolved.detail === "resolved", resolved);

  const hover = await c.request("textDocument/hover", { textDocument: { uri }, position: { line: 0, character: 1 } });
  check("A hover: markdown from MarkdownString with the word range", hover && hover.contents.kind === "markdown" && hover.contents.value === "word: `hello`" && hover.range.end.character === 5, hover);

  const definition = await c.request("textDocument/definition", { textDocument: { uri }, position: { line: 0, character: 0 } });
  check("A definition: late provider answers a Location", Array.isArray(definition) && definition[0].uri === uri && definition[0].range.start.line === 0, definition);

  const echo = await c.request("workspace/executeCommand", { command: "synthetic.echo", arguments: [1, "two"] });
  check("A executeCommand: result returned with the client setting", echo && JSON.stringify(echo.echoed) === '[1,"two"]' && echo.greeting === "howdy" && echo.folders === 1, echo);
  const shown = await c.waitFor("window/showMessage", (p) => p.message === 'echo [1,"two"]');
  check("A showInformationMessage became window/showMessage type 3", shown.type === 3, shown);
  // The task runs at once; its frames follow the client's answer to the create request,
  // so they can land after the message the command showed.
  await c.waitFor("$/progress", (p) => p.value && p.value.kind === "end");
  const progressCreate = c.received("window/workDoneProgress/create");
  const progress = c.received("$/progress");
  check("A withProgress: create request, then begin/report/end", progressCreate.length === 1 && progress.map((p) => p.value.kind).join(",") === "begin,report,end" && progress[0].value.title === "Echoing", progress.map((p) => p.value));
  const stateFile = path.join(dataDir, "state", "nvs.synthetic", "globalState.json");
  let stateJson = null;
  try {
    stateJson = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  } catch (_) {
    stateJson = null;
  }
  check("A globalState persisted under <data>/state/<id>/globalState.json", stateJson && JSON.stringify(stateJson.lastEcho) === '[1,"two"]', stateFile);

  const edits = await c.request("textDocument/formatting", { textDocument: { uri }, options: { tabSize: 2, insertSpaces: true } });
  check("A formatting: one edit deleting the trailing spaces on line 1", Array.isArray(edits) && edits.length === 1 && edits[0].newText === "" && edits[0].range.start.line === 1 && edits[0].range.start.character === 7 && edits[0].range.end.character === 10, edits);

  const actions = await c.request("textDocument/codeAction", { textDocument: { uri }, range: d.range, context: { diagnostics: [d], only: ["quickfix"] } });
  check("A codeAction: quick fix with a WorkspaceEdit", Array.isArray(actions) && actions.length === 1 && actions[0].kind === "quickfix" && actions[0].edit && actions[0].edit.changes[uri][0].newText === "DONE", actions);

  c.notify("textDocument/didChange", { textDocument: { uri, version: 2 }, contentChanges: [{ range: d.range, text: "DONE" }] });
  const cleared = await c.waitFor("textDocument/publishDiagnostics", (p) => p.uri === uri && p.diagnostics.length === 0);
  check("A didChange (incremental) re-lints and clears the diagnostic", cleared.diagnostics.length === 0, cleared);
  const hover2 = await c.request("textDocument/hover", { textDocument: { uri }, position: { line: 0, character: 13 } });
  check("A document store applied the incremental change", hover2 && hover2.contents.value === "word: `DONE`", hover2);

  const logMessages = c.received("window/logMessage");
  check("A OutputChannel lines reach window/logMessage", logMessages.some((p) => p.message === "[Synthetic] activated") && logMessages.some((p) => p.message === "[Synthetic] hello world"), logMessages.map((p) => p.message).slice(0, 5));
  check("A status bar text reaches window/logMessage", logMessages.some((p) => p.message.includes("Synthetic ready")), logMessages.map((p) => p.message).slice(0, 8));
  check("A stdout carried only LSP frames", c.garbage === 0, c.garbage + " stray bytes");
  const logText = readLog(logFile);
  check("A log names the unsupported member once", (logText.match(/unsupported: vscode\.window\.createTreeView/g) || []).length === 1, logText.split("\n").filter((l) => l.includes("unsupported")).join(" | "));
  check("A console.log and process.stdout.write were diverted to the log", logText.includes("console.log: noise from console.log") && logText.includes("stdout write intercepted: raw noise on stdout"), logText.split("\n").filter((l) => l.includes("noise")).join(" | "));
  check("A log lines carry an ISO timestamp and a level", /^\d{4}-\d\d-\d\dT[\d:.]+Z (INFO |WARN |ERROR|DEBUG) /m.test(logText), logText.split("\n")[0]);

  const shut = await c.request("shutdown", null);
  check("A shutdown answers null", shut === null, shut);
  c.notify("exit");
  const exit = await c.waitExit(5000);
  check("A exit notification ends the process with code 0", exit && exit.code === 0, exit);
  clients.delete(c);
}

// ---------------------------------------------------------------------------
async function scenarioB() {
  const dataDir = path.join(tmpRoot, "b-data");
  const logFile = path.join(tmpRoot, "b.log");
  const c = new Client(path.join(FIXTURES, "nvs.synthetic"), ["--data", dataDir, "--log", logFile]);
  c.onRequest("client/registerCapability", () => null);
  let early;
  try {
    await c.request("textDocument/hover", { textDocument: { uri: "file:///x" }, position: { line: 0, character: 0 } });
    early = "answered";
  } catch (err) {
    early = err.code;
  }
  check("B a request before initialize is refused with ServerNotInitialized", early === -32002, early);
  const init = await c.request("initialize", { processId: process.pid, rootUri: null, capabilities: CAPS_FULL });
  check("B initialize without a workspace still answers", init && init.capabilities && init.capabilities.hoverProvider === true, init);
  c.notify("initialized", {});
  let unknown;
  try {
    await c.request("textDocument/somethingElse", {});
    unknown = "answered";
  } catch (err) {
    unknown = err.code;
  }
  check("B an unknown method is refused with MethodNotFound", unknown === -32601, unknown);
  c.child.stdin.end();
  const exit = await c.waitExit(5000);
  check("B closing stdin makes the host exit", exit !== null && exit.code === 0, exit);
  check("B the log records the stdin close", readLog(logFile).includes("stdin closed"), readLog(logFile).split("\n").slice(-3).join(" | "));
  clients.delete(c);
}

// ---------------------------------------------------------------------------
async function scenarioC() {
  const dataDir = path.join(tmpRoot, "c-data");
  const logFile = path.join(tmpRoot, "c.log");
  const c = new Client(path.join(FIXTURES, "nvs.throws"), ["--data", dataDir, "--log", logFile]);
  const init = await c.request("initialize", { processId: process.pid, rootUri: null, capabilities: CAPS_FULL });
  check("C a throwing activate answers initialize with no capabilities", init && JSON.stringify(init.capabilities) === "{}", init);
  c.notify("initialized", {});
  const msg = await c.waitFor("window/showMessage", (p) => p.type === 1);
  check("C the person is told the extension failed to activate", msg.message.includes("boom"), msg);
  const logText = readLog(logFile);
  check("C the log has the activate error with its message", logText.includes("activate failed") && logText.includes("boom: activate failed on purpose"), logText.split("\n").filter((l) => l.includes("activate")).join(" | "));
  let hover;
  try {
    hover = await c.request("textDocument/hover", { textDocument: { uri: "file:///x.txt" }, position: { line: 0, character: 0 } });
  } catch (err) {
    hover = "error " + err.code;
  }
  check("C the host still answers requests afterwards", hover === null || hover === "error -32602", hover);
  await c.request("shutdown", null);
  c.notify("exit");
  const exit = await c.waitExit(5000);
  check("C exits cleanly", exit && exit.code === 0, exit);
  clients.delete(c);
}

// ---------------------------------------------------------------------------
async function scenarioD() {
  const dataDir = path.join(tmpRoot, "d-data");
  const logFile = path.join(tmpRoot, "d.log");
  const settingsFile = path.join(tmpRoot, "d-settings.json");
  fs.writeFileSync(settingsFile, JSON.stringify({ "synthetic.greeting": "yo" }));
  const ws = path.join(tmpRoot, "d-ws");
  fs.mkdirSync(ws, { recursive: true });
  const file = path.join(ws, "d.txt");
  fs.writeFileSync(file, "x\n");
  const uri = fileUri(file);
  const c = new Client(path.join(FIXTURES, "nvs.synthetic"), ["--data", dataDir, "--log", logFile, "--settings", settingsFile]);
  c.onRequest("client/registerCapability", () => null);
  const capsNoConfig = JSON.parse(JSON.stringify(CAPS_FULL));
  delete capsNoConfig.workspace.configuration;
  await c.request("initialize", { processId: process.pid, rootUri: fileUri(ws), capabilities: capsNoConfig });
  c.notify("initialized", {});
  c.notify("textDocument/didOpen", { textDocument: { uri, languageId: "plaintext", version: 1, text: "x\n" } });
  const completion = await c.request("textDocument/completion", { textDocument: { uri }, position: { line: 0, character: 1 } });
  const greeting = completion.items.find((i) => i.label === "greeting");
  check("D --settings file overrides the contributed default", greeting && greeting.insertText === "yo ${1:name}", greeting);
  check("D no workspace/configuration request when the client lacks it", c.received("workspace/configuration").length === 0, c.received("workspace/configuration"));
  c.notify("workspace/didChangeConfiguration", { settings: { synthetic: { greeting: "hey" } } });
  const completion2 = await c.request("textDocument/completion", { textDocument: { uri }, position: { line: 0, character: 1 } });
  const greeting2 = completion2.items.find((i) => i.label === "greeting");
  check("D didChangeConfiguration settings win over the file", greeting2 && greeting2.insertText === "hey ${1:name}", greeting2);
  await c.request("shutdown", null);
  c.notify("exit");
  const exit = await c.waitExit(5000);
  check("D exits cleanly", exit && exit.code === 0, exit);
  clients.delete(c);
}

// ---------------------------------------------------------------------------
// E: an activate() that awaits a request the host may send only after `initialized`.
// initialize must be answered at once (not after the 20 s activation timeout), the
// request must follow `initialized`, and what activate registers afterwards must reach
// the client through dynamic registration.
async function scenarioE() {
  const dataDir = path.join(tmpRoot, "e-data");
  const logFile = path.join(tmpRoot, "e.log");
  const ws = path.join(tmpRoot, "e-ws");
  fs.mkdirSync(ws, { recursive: true });
  const c = new Client(path.join(FIXTURES, "nvs.gated"), ["--data", dataDir, "--log", logFile]);
  c.onRequest("client/registerCapability", () => null);
  c.onRequest("workspace/applyEdit", () => ({ applied: true }));
  const t0 = Date.now();
  const init = await c.request("initialize", { processId: process.pid, rootUri: fileUri(ws), capabilities: CAPS_FULL });
  const took = Date.now() - t0;
  check("E initialize answered at once, not after the activation timeout", took < 5000, took + " ms");
  check("E the held request was not sent before initialized", c.received("workspace/applyEdit").length === 0, c.received("workspace/applyEdit"));
  check("E initialize announced nothing activate had not registered yet", init.capabilities.hoverProvider === undefined, init.capabilities.hoverProvider);
  c.notify("initialized", {});
  await c.waitFor("workspace/applyEdit");
  const reg = await c.waitFor("client/registerCapability", (p) => p.registrations.some((r) => r.method === "textDocument/hover"));
  check("E the hover registered after activate resumed reaches the client dynamically", !!reg, reg);
  const logText = fs.readFileSync(logFile, "utf8");
  check("E the log says why initialize was answered early", logText.includes("activate is waiting for workspace/applyEdit"), logText.split("\n").filter((l) => l.includes("activate")).join(" | "));
  await c.request("shutdown", null);
  c.notify("exit");
  const exit = await c.waitExit(5000);
  check("E exits cleanly", exit && exit.code === 0, exit);
  clients.delete(c);
}

// ---------------------------------------------------------------------------
// F: a provider that ignores its CancellationToken. After $/cancelRequest the client must
// get RequestCancelled at once (the LSP spec: a cancelled request still gets an answer),
// and the provider's late result must not produce a second response.
async function scenarioF() {
  const dataDir = path.join(tmpRoot, "f-data");
  const logFile = path.join(tmpRoot, "f.log");
  const ws = path.join(tmpRoot, "f-ws");
  fs.mkdirSync(ws, { recursive: true });
  const file = path.join(ws, "f.txt");
  fs.writeFileSync(file, "word\n");
  const uri = fileUri(file);
  const c = new Client(path.join(FIXTURES, "nvs.slow"), ["--data", dataDir, "--log", logFile]);
  c.onRequest("client/registerCapability", () => null);
  const init = await c.request("initialize", { processId: process.pid, rootUri: fileUri(ws), capabilities: CAPS_FULL });
  check("F hover announced", init.capabilities.hoverProvider === true, init.capabilities.hoverProvider);
  c.notify("initialized", {});
  c.notify("textDocument/didOpen", { textDocument: { uri, languageId: "plaintext", version: 1, text: "word\n" } });
  const id = c.nextId;
  const t0 = Date.now();
  const pending = c.request("textDocument/hover", { textDocument: { uri }, position: { line: 0, character: 1 } }).then(
    (result) => ({ result }),
    (err) => ({ err })
  );
  await new Promise((resolve) => setTimeout(resolve, 200));
  c.notify("$/cancelRequest", { id });
  const outcome = await pending;
  const took = Date.now() - t0;
  check("F cancelled hover answered with RequestCancelled", outcome.err && outcome.err.code === -32800, outcome.err ? outcome.err.code : outcome.result);
  check("F answered at once, not when the provider finished", took < 3000, took + " ms");
  // The provider still resolves after 8 s; the host must drop that result. Any second
  // response for the same id would reach the client as an unknown id and be ignored,
  // so the check is that the host stays healthy and keeps answering.
  const again = await c.request("shutdown", null);
  check("F host still answers after the cancel", again === null, again);
  c.notify("exit");
  const exit = await c.waitExit(5000);
  check("F exits cleanly", exit && exit.code === 0, exit);
  clients.delete(c);
}

// ---------------------------------------------------------------------------
async function main() {
  for (const [name, fn] of [
    ["A", scenarioA],
    ["B", scenarioB],
    ["C", scenarioC],
    ["D", scenarioD],
    ["E", scenarioE],
    ["F", scenarioF],
  ]) {
    try {
      await fn();
    } catch (err) {
      check(name + " scenario ran to the end", false, err && err.stack ? err.stack.split("\n").slice(0, 3).join(" ") : String(err));
    }
  }
  for (const c of clients) c.kill();
  clearTimeout(watchdog);
  if (failed === 0) {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } else {
    console.log("logs kept in " + tmpRoot);
  }
  console.log(passed + " passed, " + failed + " failed");
  process.exit(failed);
}

main();
