#!/usr/bin/env node
"use strict";
// nvs.ide extension host. Started by Neovim as a language server:
//
//   node host.js --extension <dir> --data <vsxdir> --log <file> [--settings <json>] --stdio
//
// It loads one VS Code extension with the `vscode` shim from vscode.js, activates it,
// and answers Neovim's LSP requests from the providers the extension registered.
// stdout carries LSP frames and nothing else; everything else goes to the log file.
// See README.md in this folder for the flags, the log format and what is routed.

const fs = require("fs");
const path = require("path");
const util = require("util");
const Module = require("module");
const { pathToFileURL } = require("url");
const { Connection, ResponseError, ErrorCodes, describe } = require("./lsp.js");
const { Documents } = require("./documents.js");

const HOST_VERSION = "0.1.0";
const ACTIVATE_TIMEOUT_MS = 20000;
const DEACTIVATE_TIMEOUT_MS = 2000;

// ---------------------------------------------------------------------------
// Flags.

function parseArgs(argv) {
  const out = { stdio: false, unknown: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--extension":
        out.extension = argv[++i];
        break;
      case "--data":
        out.data = argv[++i];
        break;
      case "--log":
        out.log = argv[++i];
        break;
      case "--settings":
        out.settings = argv[++i];
        break;
      case "--stdio":
        out.stdio = true;
        break;
      case "--help":
      case "-h":
        out.help = true;
        break;
      default:
        if (a.startsWith("--")) out.unknown.push(a);
    }
  }
  return out;
}

const USAGE =
  "usage: node host.js --extension <dir> --data <vsxdir> --log <file> [--settings <json-file>] --stdio\n" +
  "  --extension  the unpacked extension folder (holds package.json)\n" +
  "  --data       the vsx folder; state lands in <data>/state/<id>/\n" +
  "  --log        the log file (appended); without it the log goes to stderr\n" +
  "  --settings   a JSON file with the person's settings, flat dotted keys or nested\n" +
  "  --stdio      speak LSP on stdin/stdout (the only transport)\n";

const args = parseArgs(process.argv.slice(2));
if (args.help || !args.extension) {
  process.stderr.write(USAGE);
  process.exit(args.help ? 0 : 2);
}

// ---------------------------------------------------------------------------
// Logging: one line per entry, `<ISO time> <LEVEL> <message>`, appended to --log.

// Some extensions log a lot (Prettier writes its whole resolved config on every format),
// and the host starts with every Neovim session. Past LOG_LIMIT the log moves to
// <file>.1, replacing the previous one, so at most two files are kept.
const LOG_LIMIT = 1024 * 1024;
let logFd = null;
if (args.log) {
  try {
    fs.mkdirSync(path.dirname(path.resolve(args.log)), { recursive: true });
    try {
      if (fs.statSync(args.log).size > LOG_LIMIT) fs.renameSync(args.log, args.log + ".1");
    } catch (_) {
      // No log yet, or another host has it open: append to it as it is.
    }
    logFd = fs.openSync(args.log, "a");
  } catch (err) {
    process.stderr.write("cannot open log file " + args.log + ": " + err.message + "\n");
  }
}

function log(level, message) {
  const line = new Date().toISOString() + " " + String(level).toUpperCase().padEnd(5) + " " + String(message).replace(/\r?\n/g, "\n      ") + "\n";
  try {
    if (logFd !== null) fs.writeSync(logFd, line);
    else process.stderr.write(line);
  } catch (_) {
    // A failing log must never take the host down.
  }
}

// ---------------------------------------------------------------------------
// stdout belongs to the LSP transport. The transport keeps the original write;
// anything else that reaches stdout (an extension's console.log, a stray
// process.stdout.write) is diverted to the log so frames stay clean.

const rawStdoutWrite = process.stdout.write.bind(process.stdout);
function writeFrame(bytes) {
  rawStdoutWrite(bytes);
}
process.stdout.write = function (chunk, encoding, callback) {
  log("warn", "stdout write intercepted: " + String(chunk).trimEnd().slice(0, 500));
  if (typeof encoding === "function") encoding();
  else if (typeof callback === "function") callback();
  return true;
};
for (const method of ["log", "info", "debug", "trace", "dir", "warn", "error"]) {
  const level = method === "error" ? "error" : method === "warn" ? "warn" : "info";
  console[method] = (...a) => log(level, "console." + method + ": " + util.format(...a));
}

process.on("uncaughtException", (err) => log("error", "uncaught exception: " + describe(err)));
process.on("unhandledRejection", (err) => log("error", "unhandled rejection: " + describe(err)));

// ---------------------------------------------------------------------------
// `require("vscode")` and `import ... from "vscode"` both resolve to the shim.

const shimPath = path.join(__dirname, "vscode.js");
const originalResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  if (request === "vscode") return shimPath;
  return originalResolve.call(this, request, parent, isMain, options);
};
if (typeof Module.register === "function") {
  // ESM extensions (package.json "type": "module", as Prettier ships) resolve bare
  // specifiers in the ESM loader, which Module._resolveFilename never sees. A resolve
  // hook, registered from a data: URL so no extra file is needed, points "vscode" at
  // the same CommonJS file; format "commonjs" makes Node load it through the CJS
  // loader, so it is the one instance host.js already holds.
  const hook =
    "export async function resolve(specifier, context, next) {" +
    ' if (specifier === "vscode") return { url: ' +
    JSON.stringify(pathToFileURL(shimPath).href) +
    ', shortCircuit: true, format: "commonjs" };' +
    " return next(specifier, context); }";
  Module.register("data:text/javascript," + encodeURIComponent(hook), pathToFileURL(__filename));
} else {
  log("warn", "this Node (" + process.version + ") has no module.register; an ESM extension cannot import vscode. Node 18.19 or newer is needed for those");
}

const vscode = require("./vscode.js");
const nvs = vscode._nvs;
const convert = nvs.convert;

// ---------------------------------------------------------------------------
// The extension.

const extensionRoot = path.resolve(args.extension);
let pkg = {};
try {
  pkg = JSON.parse(fs.readFileSync(path.join(extensionRoot, "package.json"), "utf8"));
} catch (err) {
  log("error", "cannot read " + path.join(extensionRoot, "package.json") + ": " + err.message);
}
const folderName = path.basename(extensionRoot);
const extensionId = pkg.publisher && pkg.name ? pkg.publisher + "." + pkg.name : folderName;
const mainEntry = pkg.main ? path.resolve(extensionRoot, pkg.main) : null;
const dataDir = path.resolve(args.data || path.join(extensionRoot, "..", ".."));
const extension = {
  id: extensionId,
  root: extensionRoot,
  pkg,
  main: mainEntry,
  version: pkg.version,
  displayName: pkg.displayName || pkg.name || folderName,
  exports: undefined,
};

const connection = new Connection(process.stdin, writeFrame, log);
const documents = new Documents(log);
nvs.install({ log, connection, documents, extension, dataDir, logFile: args.log, settingsFile: args.settings });

log("info", "nvs-exthost " + HOST_VERSION + " on node " + process.version + " for " + extensionId + (pkg.version ? " " + pkg.version : "") + " at " + extensionRoot);
if (args.unknown.length) log("warn", "ignored flags: " + args.unknown.join(" "));
if (!args.stdio) log("warn", "--stdio not given; stdio is the only transport and is used anyway");

let context = null;
let loaded = null;
let initializeAnswered = false;
let initializedReceived = false;
let shutdownReceived = false;
let deactivated = false;
const staticKinds = new Set(); // provider kinds announced in the initialize result

async function loadExtension() {
  if (!mainEntry) {
    log("warn", "package.json has no main entry; nothing to activate");
    return null;
  }
  const isEsm = pkg.type === "module" || /\.mjs$/i.test(mainEntry);
  let mod;
  if (isEsm) {
    mod = await import(pathToFileURL(mainEntry).href);
  } else {
    try {
      mod = require(mainEntry);
    } catch (err) {
      if (err && err.code === "ERR_REQUIRE_ESM") mod = await import(pathToFileURL(mainEntry).href);
      else throw err;
    }
  }
  const pick = (name) => {
    if (mod && typeof mod[name] === "function") return mod[name];
    if (mod && mod.default && typeof mod.default[name] === "function") return mod.default[name];
    return null;
  };
  return { mod, activate: pick("activate"), deactivate: pick("deactivate"), esm: isEsm };
}

// ---------------------------------------------------------------------------
// Capabilities.

const KINDS = {
  completion: { cap: "completionProvider", method: "textDocument/completion", client: ["textDocument", "completion"] },
  hover: { cap: "hoverProvider", method: "textDocument/hover", client: ["textDocument", "hover"] },
  definition: { cap: "definitionProvider", method: "textDocument/definition", client: ["textDocument", "definition"] },
  declaration: { cap: "declarationProvider", method: "textDocument/declaration", client: ["textDocument", "declaration"] },
  implementation: { cap: "implementationProvider", method: "textDocument/implementation", client: ["textDocument", "implementation"] },
  typeDefinition: { cap: "typeDefinitionProvider", method: "textDocument/typeDefinition", client: ["textDocument", "typeDefinition"] },
  references: { cap: "referencesProvider", method: "textDocument/references", client: ["textDocument", "references"] },
  documentHighlight: { cap: "documentHighlightProvider", method: "textDocument/documentHighlight", client: ["textDocument", "documentHighlight"] },
  documentSymbol: { cap: "documentSymbolProvider", method: "textDocument/documentSymbol", client: ["textDocument", "documentSymbol"] },
  workspaceSymbol: { cap: "workspaceSymbolProvider", method: "workspace/symbol", client: ["workspace", "symbol"] },
  codeAction: { cap: "codeActionProvider", method: "textDocument/codeAction", client: ["textDocument", "codeAction"] },
  codeLens: { cap: "codeLensProvider", method: "textDocument/codeLens", client: ["textDocument", "codeLens"] },
  documentLink: { cap: "documentLinkProvider", method: "textDocument/documentLink", client: ["textDocument", "documentLink"] },
  foldingRange: { cap: "foldingRangeProvider", method: "textDocument/foldingRange", client: ["textDocument", "foldingRange"] },
  rename: { cap: "renameProvider", method: "textDocument/rename", client: ["textDocument", "rename"] },
  signatureHelp: { cap: "signatureHelpProvider", method: "textDocument/signatureHelp", client: ["textDocument", "signatureHelp"] },
  formatting: { cap: "documentFormattingProvider", method: "textDocument/formatting", client: ["textDocument", "formatting"] },
  rangeFormatting: { cap: "documentRangeFormattingProvider", method: "textDocument/rangeFormatting", client: ["textDocument", "rangeFormatting"] },
};

function union(lists) {
  const out = [];
  for (const list of lists) {
    if (!Array.isArray(list)) continue;
    for (const v of list) if (typeof v === "string" && !out.includes(v)) out.push(v);
  }
  return out;
}

function optionsFor(kind, entries) {
  const has = (name) => entries.some((e) => e.provider && typeof e.provider[name] === "function");
  switch (kind) {
    case "completion":
      return { triggerCharacters: union(entries.map((e) => e.options.triggerCharacters)), resolveProvider: has("resolveCompletionItem") };
    case "codeAction": {
      const kinds = union(entries.map((e) => (e.options.providedCodeActionKinds || []).map((k) => k && k.value)));
      const out = { resolveProvider: has("resolveCodeAction") };
      if (kinds.length) out.codeActionKinds = kinds;
      return out;
    }
    case "rename":
      return { prepareProvider: has("prepareRename") };
    case "signatureHelp":
      return {
        triggerCharacters: union(entries.map((e) => e.options.triggerCharacters)),
        retriggerCharacters: union(entries.map((e) => e.options.retriggerCharacters)),
      };
    case "codeLens":
      return { resolveProvider: has("resolveCodeLens") };
    case "documentLink":
      return { resolveProvider: has("resolveDocumentLink") };
    case "documentSymbol": {
      const labelled = entries.find((e) => e.options && e.options.label);
      return labelled ? { label: labelled.options.label } : true;
    }
    default:
      return true;
  }
}

function buildCapabilities() {
  const caps = {
    positionEncoding: "utf-16",
    textDocumentSync: { openClose: true, change: 2, save: { includeText: false } },
  };
  staticKinds.clear();
  for (const kind of Object.keys(KINDS)) {
    const entries = nvs.providers.get(kind);
    if (entries && entries.length) {
      caps[KINDS[kind].cap] = optionsFor(kind, entries);
      staticKinds.add(kind);
    }
  }
  if (nvs.commands.size) caps.executeCommandProvider = { commands: Array.from(nvs.commands.keys()) };
  return caps;
}

function clientAllowsDynamic(kind) {
  const spec = KINDS[kind];
  const caps = nvs.state.clientCapabilities || {};
  const node = caps[spec.client[0]] && caps[spec.client[0]][spec.client[1]];
  return !!(node && node.dynamicRegistration);
}

// Providers registered after the initialize response are announced dynamically when
// the client allows it; otherwise the log says why they cannot be reached.
nvs.hooks.onProviderChange = (kind, entry, added) => {
  if (!initializeAnswered || !KINDS[kind]) return;
  const method = KINDS[kind].method;
  if (!clientAllowsDynamic(kind)) {
    if (added && !staticKinds.has(kind)) {
      log("warn", kind + " provider registered after initialize, and the client does not support dynamic registration for " + method + "; it is unreachable until the host restarts");
    }
    return;
  }
  const registerOptions = Object.assign({}, kind === "workspaceSymbol" ? {} : { documentSelector: convert.toLspSelector(entry.selector) });
  const extra = optionsFor(kind, [entry]);
  if (extra && typeof extra === "object") Object.assign(registerOptions, extra);
  const request = added
    ? nvs.clientRequest("client/registerCapability", { registrations: [{ id: entry.id, method, registerOptions }] })
    : nvs.clientRequest("client/unregisterCapability", { unregisterations: [{ id: entry.id, method }] });
  request.then(
    () => log("info", (added ? "registered " : "unregistered ") + method + " dynamically as " + entry.id),
    (err) => log("warn", "dynamic " + (added ? "registration" : "unregistration") + " of " + method + " failed: " + describe(err))
  );
};

nvs.hooks.onCommandChange = (id, added) => {
  if (initializeAnswered && added) log("warn", "command " + id + " registered after initialize; Neovim only executes commands listed in the initialize result");
};

// ---------------------------------------------------------------------------
// Result caches: items handed to the client carry `data: { gen, nvs }` so a later
// resolve request finds the original object and provider.

class ResultCache {
  constructor(max) {
    this._gens = new Map();
    this._seq = 0;
    this._max = max || 8;
  }
  begin() {
    const gen = ++this._seq;
    const list = [];
    this._gens.set(gen, list);
    while (this._gens.size > this._max) this._gens.delete(this._gens.keys().next().value);
    return {
      put(value, entry) {
        list.push({ value, entry });
        return { gen, nvs: list.length - 1 };
      },
    };
  }
  get(data) {
    if (!data || typeof data !== "object") return null;
    const list = this._gens.get(data.gen);
    return list ? list[data.nvs] || null : null;
  }
}

const completionCache = new ResultCache();
const codeActionCache = new ResultCache();
const codeLensCache = new ResultCache();
const documentLinkCache = new ResultCache();

// ---------------------------------------------------------------------------
// Request helpers.

function getDocument(uri) {
  const doc = documents.get(uri);
  if (doc) return doc;
  try {
    const opened = documents.openExternal(vscode.Uri.parse(uri));
    if (opened) return opened;
  } catch (err) {
    log("warn", "cannot read " + uri + ": " + err.message);
  }
  throw new ResponseError(ErrorCodes.InvalidParams, "unknown document " + uri);
}

function withToken(ctx, fn) {
  const cts = nvs.makeToken(ctx);
  return Promise.resolve()
    .then(() => fn(cts.token))
    .finally(() => cts.dispose());
}

async function callProvider(entry, name, ...providerArgs) {
  const fn = entry.provider && entry.provider[name];
  if (typeof fn !== "function") return undefined;
  try {
    return await fn.apply(entry.provider, providerArgs);
  } catch (err) {
    if (err instanceof vscode.CancellationError) return undefined;
    log("error", entry.kind + " provider " + entry.id + "." + name + " threw: " + describe(err));
    return undefined;
  }
}

// First provider (best selector score first) whose answer is not empty.
async function firstResult(entries, fn) {
  for (const entry of entries) {
    const r = await fn(entry);
    if (r === undefined || r === null) continue;
    if (Array.isArray(r) && r.length === 0) continue;
    return r;
  }
  return null;
}

// Every provider's answer, concatenated.
async function allResults(entries, fn) {
  const out = [];
  for (const entry of entries) {
    const r = await fn(entry);
    if (r === undefined || r === null) continue;
    if (Array.isArray(r)) out.push(...r);
    else out.push(r);
  }
  return out;
}

function positionParams(params) {
  return { doc: getDocument(params.textDocument.uri), pos: convert.fromLspPosition(params.position) };
}

function requireInitialized() {
  if (!initializeAnswered) throw new ResponseError(ErrorCodes.ServerNotInitialized, "initialize first");
}

function onRequest(method, handler) {
  connection.onRequest(method, (params, ctx) => {
    requireInitialized();
    return handler(params, ctx);
  });
}

// ---------------------------------------------------------------------------
// Lifecycle.

connection.onRequest("initialize", async (params) => {
  nvs.handleInitialize(params);
  const ci = (params && params.clientInfo) || {};
  log("info", "initialize from " + (ci.name || "client") + " " + (ci.version || "") + "; workspace " + nvs.state.workspaceFolders.map((f) => f.uri.fsPath).join(", "));
  context = nvs.buildContext();
  let ok = false;
  try {
    loaded = await loadExtension();
    if (loaded && loaded.activate) {
      const started = Date.now();
      // An activate() that awaits a request the client may answer only after `initialized`
      // (workspace/configuration, for one) cannot finish while initialize is unanswered:
      // the shim holds such a request and tells us, and we answer initialize at once
      // instead of waiting out the timeout. What activate registers later is announced
      // dynamically where the client allows it.
      let gatedMethod = null;
      const gated = new Promise((resolve) => {
        nvs.hooks.onGatedRequest = (method) => {
          gatedMethod = method;
          resolve("gated");
        };
      });
      const running = Promise.resolve(loaded.activate(context));
      let timer;
      const timeout = new Promise((resolve) => {
        timer = setTimeout(() => resolve("timeout"), ACTIVATE_TIMEOUT_MS);
      });
      const outcome = await Promise.race([running.then((v) => ({ value: v })), timeout, gated]);
      clearTimeout(timer);
      nvs.hooks.onGatedRequest = null;
      if (outcome === "timeout" || outcome === "gated") {
        log(
          "warn",
          outcome === "gated"
            ? "activate is waiting for " + gatedMethod + ", which the client answers only after initialize; answering initialize with what is registered so far"
            : "activate still running after " + ACTIVATE_TIMEOUT_MS + " ms; answering initialize with what is registered so far"
        );
        running.then(
          (v) => {
            extension.exports = v;
            log("info", "activate finished late, " + (Date.now() - started) + " ms");
          },
          (err) => log("error", "activate failed late: " + describe(err))
        );
      } else {
        extension.exports = outcome.value;
        log("info", "activated " + extensionId + " in " + (Date.now() - started) + " ms (" + (loaded.esm ? "esm" : "commonjs") + ")");
      }
      ok = true;
    } else if (loaded) {
      log("warn", "main entry exports no activate function; nothing registered");
      ok = true;
    }
  } catch (err) {
    log("error", "activate failed: " + describe(err));
    connection.sendNotification("window/showMessage", {
      type: nvs.MessageType.Error,
      message: extension.displayName + " failed to activate: " + (err && err.message ? err.message : String(err)),
    });
  }
  const capabilities = ok ? buildCapabilities() : {};
  initializeAnswered = true;
  log("info", "capabilities: " + Object.keys(capabilities).join(", "));
  return { capabilities, serverInfo: { name: "nvs-exthost", version: HOST_VERSION } };
});

connection.onNotification("initialized", () => {
  initializedReceived = true;
  nvs.setInitialized().catch((err) => log("warn", "initialized handling failed: " + describe(err)));
});

async function deactivateExtension() {
  if (deactivated) return;
  deactivated = true;
  try {
    nvs.disposeAll(context);
  } catch (err) {
    log("warn", "dispose failed: " + describe(err));
  }
  if (loaded && loaded.deactivate) {
    let timer;
    const timeout = new Promise((resolve) => {
      timer = setTimeout(() => resolve("timeout"), DEACTIVATE_TIMEOUT_MS);
    });
    try {
      const r = await Promise.race([Promise.resolve().then(() => loaded.deactivate()), timeout]);
      if (r === "timeout") log("warn", "deactivate did not finish within " + DEACTIVATE_TIMEOUT_MS + " ms");
    } catch (err) {
      log("warn", "deactivate failed: " + describe(err));
    }
    clearTimeout(timer);
  }
}

function exitProcess(code) {
  deactivateExtension().finally(() => {
    log("info", "exit " + code);
    try {
      if (logFd !== null) fs.closeSync(logFd);
    } catch (_) {
      // Nothing else to do with a log that will not close.
    }
    logFd = null;
    process.exit(code);
  });
}

connection.onRequest("shutdown", async () => {
  shutdownReceived = true;
  await deactivateExtension();
  return null;
});

connection.onNotification("exit", () => exitProcess(shutdownReceived ? 0 : 1));

connection.on("close", () => {
  log("info", "stdin closed; the client is gone");
  exitProcess(0);
});

// ---------------------------------------------------------------------------
// Document sync and workspace notifications.

connection.onNotification("textDocument/didOpen", (p) => {
  documents.open(p);
});
connection.onNotification("textDocument/didChange", (p) => {
  documents.change(p);
});
connection.onNotification("textDocument/didClose", (p) => {
  documents.close(p);
});
connection.onNotification("textDocument/didSave", (p) => {
  documents.save(p);
});
connection.onNotification("textDocument/willSave", (p) => {
  documents.willSave(p);
});
connection.onNotification("workspace/didChangeConfiguration", (p) => {
  if (p && p.settings && typeof p.settings === "object") nvs.applyClientSettings(p.settings);
  else nvs.refreshFromClient();
});
connection.onNotification("workspace/didChangeWorkspaceFolders", (p) => {
  if (p && p.event) nvs.handleWorkspaceFoldersChanged(p.event);
});
connection.onNotification("workspace/didChangeWatchedFiles", () => {
  // The host never registers for these; extensions watch through fs.watch.
});
connection.onNotification("$/setTrace", () => {});
connection.onNotification("$/logTrace", () => {});

// ---------------------------------------------------------------------------
// Language features.

onRequest("textDocument/completion", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const c = params.context || {};
    const context = { triggerKind: Math.max(0, (c.triggerKind || 1) - 1), triggerCharacter: c.triggerCharacter };
    const cache = completionCache.begin();
    const items = [];
    let isIncomplete = false;
    for (const entry of nvs.providersFor("completion", doc)) {
      const r = await callProvider(entry, "provideCompletionItems", doc, pos, token, context);
      if (!r) continue;
      const list = Array.isArray(r) ? r : r.items || [];
      if (r.isIncomplete) isIncomplete = true;
      for (const item of list) {
        if (item) items.push(convert.toLspCompletionItem(item, cache.put(item, entry)));
      }
    }
    return { isIncomplete, items };
  })
);

onRequest("completionItem/resolve", (params, ctx) =>
  withToken(ctx, async (token) => {
    const cached = completionCache.get(params.data);
    if (!cached) return params;
    const r = await callProvider(cached.entry, "resolveCompletionItem", cached.value, token);
    return convert.toLspCompletionItem(r || cached.value, params.data);
  })
);

onRequest("textDocument/hover", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const hovers = await allResults(nvs.providersFor("hover", doc), (e) => callProvider(e, "provideHover", doc, pos, token));
    if (!hovers.length) return null;
    const contents = [];
    let range;
    for (const h of hovers) {
      if (!h) continue;
      contents.push(...(Array.isArray(h.contents) ? h.contents : [h.contents]));
      if (!range && h.range) range = h.range;
    }
    return convert.toLspHover({ contents, range });
  })
);

for (const [kind, name] of [
  ["definition", "provideDefinition"],
  ["declaration", "provideDeclaration"],
  ["implementation", "provideImplementation"],
  ["typeDefinition", "provideTypeDefinition"],
]) {
  onRequest(KINDS[kind].method, (params, ctx) =>
    withToken(ctx, async (token) => {
      const { doc, pos } = positionParams(params);
      const locations = await allResults(nvs.providersFor(kind, doc), (e) => callProvider(e, name, doc, pos, token));
      return locations.length ? convert.toLspLocations(locations) : null;
    })
  );
}

onRequest("textDocument/references", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const context = { includeDeclaration: !!(params.context && params.context.includeDeclaration) };
    const locations = await allResults(nvs.providersFor("references", doc), (e) => callProvider(e, "provideReferences", doc, pos, context, token));
    return locations.length ? convert.toLspLocations(locations) : null;
  })
);

onRequest("textDocument/documentHighlight", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const r = await firstResult(nvs.providersFor("documentHighlight", doc), (e) => callProvider(e, "provideDocumentHighlights", doc, pos, token));
    return r ? r.map(convert.toLspDocumentHighlight) : null;
  })
);

onRequest("textDocument/documentSymbol", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const r = await firstResult(nvs.providersFor("documentSymbol", doc), (e) => callProvider(e, "provideDocumentSymbols", doc, token));
    return r ? convert.toLspSymbols(r) : null;
  })
);

onRequest("workspace/symbol", (params, ctx) =>
  withToken(ctx, async (token) => {
    const entries = nvs.providers.get("workspaceSymbol") || [];
    const r = await allResults(entries, (e) => callProvider(e, "provideWorkspaceSymbols", params.query || "", token));
    return r.length ? r.map(convert.toLspSymbolInformation) : null;
  })
);

onRequest("textDocument/codeAction", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const range = convert.fromLspRange(params.range);
    const c = params.context || {};
    const only = Array.isArray(c.only) ? c.only.map((k) => new vscode.CodeActionKind(k)) : undefined;
    const context = {
      diagnostics: (c.diagnostics || []).map(convert.fromLspDiagnostic),
      only: only && only.length ? only[0] : undefined,
      triggerKind: c.triggerKind || vscode.CodeActionTriggerKind.Invoke,
    };
    const cache = codeActionCache.begin();
    const out = [];
    for (const entry of nvs.providersFor("codeAction", doc)) {
      const provided = entry.options.providedCodeActionKinds;
      if (only && Array.isArray(provided) && provided.length && !provided.some((pk) => only.some((ok) => ok.intersects(pk)))) continue;
      const r = await callProvider(entry, "provideCodeActions", doc, range, context, token);
      if (!Array.isArray(r)) continue;
      for (const action of r) {
        if (!action) continue;
        if (only && action.kind && !only.some((ok) => ok.contains(action.kind))) continue;
        out.push(convert.toLspCodeAction(action, cache.put(action, entry)));
      }
    }
    return out;
  })
);

onRequest("codeAction/resolve", (params, ctx) =>
  withToken(ctx, async (token) => {
    const cached = codeActionCache.get(params.data);
    if (!cached) return params;
    const r = await callProvider(cached.entry, "resolveCodeAction", cached.value, token);
    return convert.toLspCodeAction(r || cached.value, params.data);
  })
);

onRequest("textDocument/codeLens", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const cache = codeLensCache.begin();
    const out = [];
    for (const entry of nvs.providersFor("codeLens", doc)) {
      const r = await callProvider(entry, "provideCodeLenses", doc, token);
      if (Array.isArray(r)) for (const lens of r) if (lens) out.push(convert.toLspCodeLens(lens, cache.put(lens, entry)));
    }
    return out;
  })
);

onRequest("codeLens/resolve", (params, ctx) =>
  withToken(ctx, async (token) => {
    const cached = codeLensCache.get(params.data);
    if (!cached) return params;
    const r = await callProvider(cached.entry, "resolveCodeLens", cached.value, token);
    return convert.toLspCodeLens(r || cached.value, params.data);
  })
);

onRequest("textDocument/documentLink", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const cache = documentLinkCache.begin();
    const out = [];
    for (const entry of nvs.providersFor("documentLink", doc)) {
      const r = await callProvider(entry, "provideDocumentLinks", doc, token);
      if (Array.isArray(r)) for (const link of r) if (link) out.push(convert.toLspDocumentLink(link, cache.put(link, entry)));
    }
    return out;
  })
);

onRequest("documentLink/resolve", (params, ctx) =>
  withToken(ctx, async (token) => {
    const cached = documentLinkCache.get(params.data);
    if (!cached) return params;
    const r = await callProvider(cached.entry, "resolveDocumentLink", cached.value, token);
    return convert.toLspDocumentLink(r || cached.value, params.data);
  })
);

onRequest("textDocument/foldingRange", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const r = await firstResult(nvs.providersFor("foldingRange", doc), (e) => callProvider(e, "provideFoldingRanges", doc, {}, token));
    return r ? r.map(convert.toLspFoldingRange) : null;
  })
);

onRequest("textDocument/prepareRename", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const entries = nvs.providersFor("rename", doc).filter((e) => typeof e.provider.prepareRename === "function");
    const r = await firstResult(entries, (e) => callProvider(e, "prepareRename", doc, pos, token));
    if (!r) return null;
    if (r instanceof vscode.Range) return convert.toLspRange(r);
    return { range: convert.toLspRange(r.range), placeholder: r.placeholder };
  })
);

onRequest("textDocument/rename", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const r = await firstResult(nvs.providersFor("rename", doc), (e) => callProvider(e, "provideRenameEdits", doc, pos, params.newName, token));
    return r ? convert.toLspWorkspaceEdit(r) : null;
  })
);

onRequest("textDocument/signatureHelp", (params, ctx) =>
  withToken(ctx, async (token) => {
    const { doc, pos } = positionParams(params);
    const c = params.context || {};
    const context = {
      triggerKind: c.triggerKind || vscode.SignatureHelpTriggerKind.Invoke,
      triggerCharacter: c.triggerCharacter,
      isRetrigger: !!c.isRetrigger,
      activeSignatureHelp: c.activeSignatureHelp,
    };
    const r = await firstResult(nvs.providersFor("signatureHelp", doc), (e) => callProvider(e, "provideSignatureHelp", doc, pos, token, context));
    return r ? convert.toLspSignatureHelp(r) : null;
  })
);

onRequest("textDocument/formatting", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const options = Object.assign({ tabSize: 4, insertSpaces: true }, params.options || {});
    // One formatter, like VS Code: the best-scoring provider that answers.
    for (const entry of nvs.providersFor("formatting", doc)) {
      const r = await callProvider(entry, "provideDocumentFormattingEdits", doc, options, token);
      if (Array.isArray(r)) return convert.toLspTextEdits(r);
    }
    return null;
  })
);

onRequest("textDocument/rangeFormatting", (params, ctx) =>
  withToken(ctx, async (token) => {
    const doc = getDocument(params.textDocument.uri);
    const range = convert.fromLspRange(params.range);
    const options = Object.assign({ tabSize: 4, insertSpaces: true }, params.options || {});
    for (const entry of nvs.providersFor("rangeFormatting", doc)) {
      const r = await callProvider(entry, "provideDocumentRangeFormattingEdits", doc, range, options, token);
      if (Array.isArray(r)) return convert.toLspTextEdits(r);
    }
    return null;
  })
);

onRequest("workspace/executeCommand", async (params) => {
  const command = params && params.command;
  if (!nvs.commands.has(command)) throw new ResponseError(ErrorCodes.InvalidParams, "unknown command " + command);
  try {
    const result = await vscode.commands.executeCommand(command, ...(params.arguments || []));
    return result === undefined ? null : result;
  } catch (err) {
    log("error", "command " + command + " failed: " + describe(err));
    throw new ResponseError(ErrorCodes.RequestFailed, command + ": " + (err && err.message ? err.message : String(err)));
  }
});

connection.listen();
