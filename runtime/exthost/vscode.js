"use strict";
// The `vscode` module an extension receives inside the nvs.ide extension host.
//
// Everything an extension registers (providers, commands, diagnostics) lands in the
// registries at the bottom of this file; host.js reads them to answer Neovim over
// LSP. Everything the extension asks of the editor (messages, documents, settings,
// the file system) is answered here, either locally or by an LSP request to Neovim.
//
// Members that are not implemented are never missing: a namespace member that does
// not exist logs `unsupported: vscode.<path>` once and returns a phantom, a callable
// value that resolves to undefined when awaited, so the extension keeps running.
//
// The file ends with one literal `module.exports = { ... }` on purpose: Node's
// CommonJS lexer reads that list to give ESM extensions their named imports
// (`import { window } from "vscode"`), and a computed export would break them.

const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const { Documents, TextDocument } = require("./documents.js");

// ---------------------------------------------------------------------------
// Host state, filled by _nvs.install() before the extension is loaded.

const host = {
  log: () => {},
  connection: null,
  documents: null,
  extension: null, // { id, root, pkg, main, version, displayName }
  dataDir: null,
  stateDir: null,
  logFile: null,
  settingsFile: null,
};

const state = {
  clientCapabilities: {},
  clientInfo: null,
  workspaceFolders: [], // vscode.WorkspaceFolder[]
  initialized: false,
};

function log(level, message) {
  host.log(level, message);
}

const reported = new Set();
function unsupported(name) {
  if (reported.has(name)) return;
  reported.add(name);
  log("warn", "unsupported: vscode." + name);
}

// A phantom stands in for an API member the shim does not have: callable, awaitable
// (resolves to undefined), disposable, and every property on it is another phantom.
function phantom(name) {
  const fn = function () {
    return phantom(name + "()");
  };
  return new Proxy(fn, {
    get(_t, key) {
      if (key === "then") return (resolve) => resolve(undefined);
      if (key === Symbol.toPrimitive || key === "toString" || key === "valueOf") return () => "";
      if (key === Symbol.iterator) return () => [][Symbol.iterator]();
      if (key === "toJSON") return () => null;
      if (typeof key !== "string") return undefined;
      if (key === "constructor") return fn.constructor;
      return phantom(name + "." + key);
    },
    apply() {
      return phantom(name + "()");
    },
    construct() {
      return phantom("new " + name);
    },
  });
}

// A namespace object whose unknown members log once and come back as phantoms.
const NAMESPACE_SKIP = new Set(["then", "toJSON", "constructor", "inspect", "__esModule", "default", "nodeType", "$$typeof"]);
function namespace(name, impl) {
  return new Proxy(impl, {
    get(target, key, receiver) {
      if (typeof key !== "string" || key in target) return Reflect.get(target, key, receiver);
      if (NAMESPACE_SKIP.has(key)) return undefined;
      unsupported(name + "." + key);
      return phantom(name + "." + key);
    },
  });
}

// ---------------------------------------------------------------------------
// Small utilities.

function isPlainObject(v) {
  return v !== null && typeof v === "object" && (Object.getPrototypeOf(v) === Object.prototype || Object.getPrototypeOf(v) === null);
}

function clone(v) {
  if (Array.isArray(v)) return v.map(clone);
  if (isPlainObject(v)) {
    const out = {};
    for (const k of Object.keys(v)) out[k] = clone(v[k]);
    return out;
  }
  return v;
}

function deepMerge(base, over) {
  if (!isPlainObject(base) || !isPlainObject(over)) return clone(over === undefined ? base : over);
  const out = clone(base);
  for (const k of Object.keys(over)) {
    out[k] = isPlainObject(out[k]) && isPlainObject(over[k]) ? deepMerge(out[k], over[k]) : clone(over[k]);
  }
  return out;
}

function getPath(obj, dotted) {
  if (!dotted) return obj;
  let cur = obj;
  for (const part of dotted.split(".")) {
    if (!isPlainObject(cur) || !(part in cur)) return undefined;
    cur = cur[part];
  }
  return cur;
}

function setPath(obj, dotted, value) {
  const parts = dotted.split(".");
  let cur = obj;
  for (let i = 0; i < parts.length - 1; i++) {
    if (!isPlainObject(cur[parts[i]])) cur[parts[i]] = {};
    cur = cur[parts[i]];
  }
  cur[parts[parts.length - 1]] = value;
}

// Settings files may use flat dotted keys ("prettier.semi": false) or nested objects.
function normalizeSettings(obj) {
  const out = {};
  if (!isPlainObject(obj)) return out;
  for (const k of Object.keys(obj)) {
    if (k.startsWith("[")) continue; // language-scoped overrides are not supported
    if (k.includes(".")) {
      const existing = getPath(out, k);
      setPath(out, k, isPlainObject(existing) && isPlainObject(obj[k]) ? deepMerge(existing, obj[k]) : clone(obj[k]));
    } else {
      out[k] = isPlainObject(out[k]) && isPlainObject(obj[k]) ? deepMerge(out[k], obj[k]) : clone(obj[k]);
    }
  }
  return out;
}

function flatten(obj, prefix, out) {
  out = out || {};
  if (!isPlainObject(obj)) {
    if (prefix) out[prefix] = obj;
    return out;
  }
  for (const k of Object.keys(obj)) {
    const key = prefix ? prefix + "." + k : k;
    if (isPlainObject(obj[k])) flatten(obj[k], key, out);
    else out[key] = obj[k];
  }
  return out;
}

function readJsonFile(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    if (err && err.code !== "ENOENT") log("warn", "could not read " + file + ": " + err.message);
    return null;
  }
}

function writeJsonFile(file, data) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
  } catch (err) {
    log("error", "could not write " + file + ": " + err.message);
  }
}

function describe(err) {
  return err instanceof Error ? err.stack || err.message : String(err);
}

// Glob to RegExp: **, *, ?, {a,b}, [set]. Paths are compared with forward slashes,
// case-insensitively on Windows.
const globCache = new Map();
function globToRegExp(glob) {
  let cached = globCache.get(glob);
  if (cached) return cached;
  let re = "";
  let i = 0;
  const g = glob.replace(/\\/g, "/");
  while (i < g.length) {
    const c = g[i];
    if (c === "*") {
      if (g[i + 1] === "*") {
        // "**/" matches zero or more directories; a trailing "**" matches anything.
        if (g[i + 2] === "/") {
          re += "(?:.*/)?";
          i += 3;
        } else {
          re += ".*";
          i += 2;
        }
      } else {
        re += "[^/]*";
        i++;
      }
    } else if (c === "?") {
      re += "[^/]";
      i++;
    } else if (c === "{") {
      const end = g.indexOf("}", i);
      if (end < 0) {
        re += "\\{";
        i++;
      } else {
        const alts = g.slice(i + 1, end).split(",").map((a) => globToRegExp(a).source.replace(/^\^|\$$/g, ""));
        re += "(?:" + alts.join("|") + ")";
        i = end + 1;
      }
    } else if (c === "[") {
      const end = g.indexOf("]", i);
      if (end < 0) {
        re += "\\[";
        i++;
      } else {
        let set = g.slice(i + 1, end);
        if (set[0] === "!") set = "^" + set.slice(1);
        re += "[" + set.replace(/\\/g, "\\\\") + "]";
        i = end + 1;
      }
    } else {
      re += c.replace(/[.+^$()|\\/]/g, "\\$&");
      i++;
    }
  }
  cached = new RegExp("^" + re + "$", process.platform === "win32" ? "i" : "");
  globCache.set(glob, cached);
  return cached;
}

function slashes(p) {
  return String(p).replace(/\\/g, "/");
}

function isAbsoluteGlob(pattern) {
  return /^([A-Za-z]:)?\//.test(slashes(pattern)) || /^[A-Za-z]:/.test(pattern);
}

// Matches a glob (string or RelativePattern) against an absolute file path. A
// relative glob is tried against the path relative to each workspace folder, which
// is how VS Code scopes "**/package.json".
function matchGlob(pattern, fsPath) {
  const target = slashes(fsPath);
  if (pattern instanceof RelativePattern) {
    const base = slashes(pattern.baseUri.fsPath).replace(/\/$/, "");
    const rel = relativeTo(base, target);
    return rel !== null && globToRegExp(pattern.pattern).test(rel);
  }
  const glob = String(pattern);
  if (isAbsoluteGlob(glob)) return globToRegExp(glob).test(target);
  const re = globToRegExp(glob);
  for (const folder of state.workspaceFolders) {
    const rel = relativeTo(slashes(folder.uri.fsPath).replace(/\/$/, ""), target);
    if (rel !== null && re.test(rel)) return true;
  }
  return re.test(target);
}

function relativeTo(base, target) {
  const b = process.platform === "win32" ? base.toLowerCase() : base;
  const t = process.platform === "win32" ? target.toLowerCase() : target;
  if (t === b) return "";
  if (!t.startsWith(b + "/")) return null;
  return target.slice(base.length + 1);
}

// ---------------------------------------------------------------------------
// Uri

const URI_RE = /^(([^:/?#]+?):)?(\/\/([^/?#]*))?([^?#]*)(\?([^#]*))?(#(.*))?/;

function decodeComponent(s) {
  if (!s || !s.includes("%")) return s || "";
  try {
    return decodeURIComponent(s);
  } catch (_) {
    return s;
  }
}

// The character set Neovim keeps unencoded in file uris (RFC 3986 in vim.uri), so a
// uri built here from a path equals the one Neovim sends for that buffer.
function encodePathComponent(p) {
  return p.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/]+/g, (run) => encodeURIComponent(run));
}

function encodeQueryComponent(q) {
  return q.replace(/[^A-Za-z0-9\-._~!$&'()*+,;=:@/?]+/g, (run) => encodeURIComponent(run));
}

class Uri {
  constructor(scheme, authority, uriPath, query, fragment, original) {
    this.scheme = scheme || "";
    this.authority = authority || "";
    this.path = uriPath || "";
    this.query = query || "";
    this.fragment = fragment || "";
    if (this.authority && this.path && this.path[0] !== "/") this.path = "/" + this.path;
    Object.defineProperty(this, "_original", { value: original, enumerable: false, writable: true });
  }

  static parse(value, _strict) {
    const s = String(value);
    const m = URI_RE.exec(s) || [];
    return new Uri(m[2] || "", decodeComponent(m[4]), decodeComponent(m[5]), decodeComponent(m[7]), decodeComponent(m[9]), s);
  }

  static file(fsPath) {
    let p = String(fsPath);
    let authority = "";
    if (process.platform === "win32") p = p.replace(/\\/g, "/");
    if (p.startsWith("//")) {
      const idx = p.indexOf("/", 2);
      if (idx < 0) {
        authority = p.slice(2);
        p = "/";
      } else {
        authority = p.slice(2, idx);
        p = p.slice(idx);
      }
    }
    if (p[0] !== "/") p = "/" + p;
    return new Uri("file", authority, p, "", "");
  }

  static from(components) {
    return new Uri(components.scheme, components.authority, components.path, components.query, components.fragment);
  }

  static joinPath(base, ...segments) {
    if (!base.path) throw new Error("[UriError]: cannot call joinPath on URI without path");
    return base.with({ path: path.posix.join(base.path, ...segments) });
  }

  static isUri(thing) {
    return thing instanceof Uri;
  }

  get fsPath() {
    let value;
    if (this.authority && this.path.length > 1 && this.scheme === "file") value = "//" + this.authority + this.path;
    else if (/^\/[A-Za-z]:/.test(this.path)) value = this.path.slice(1);
    else value = this.path;
    if (process.platform === "win32") value = value.replace(/\//g, "\\");
    return value;
  }

  with(change) {
    if (!change) return this;
    const pick = (k) => (change[k] === undefined ? this[k] : change[k] === null ? "" : change[k]);
    return new Uri(pick("scheme"), pick("authority"), pick("path"), pick("query"), pick("fragment"));
  }

  toString(skipEncoding) {
    if (this._original !== undefined && !skipEncoding) return this._original;
    let res = "";
    if (this.scheme) res += this.scheme + ":";
    if (this.authority || this.scheme === "file") res += "//";
    if (this.authority) res += skipEncoding ? this.authority : encodePathComponent(this.authority);
    if (this.path) res += skipEncoding ? this.path : encodePathComponent(this.path);
    if (this.query) res += "?" + (skipEncoding ? this.query : encodeQueryComponent(this.query));
    if (this.fragment) res += "#" + (skipEncoding ? this.fragment : encodeQueryComponent(this.fragment));
    return res;
  }

  toJSON() {
    return {
      $mid: 1,
      scheme: this.scheme,
      authority: this.authority,
      path: this.path,
      query: this.query,
      fragment: this.fragment,
      fsPath: this.fsPath,
      external: this.toString(),
    };
  }
}

function asUri(value) {
  if (value instanceof Uri) return value;
  if (typeof value === "string") return Uri.parse(value);
  if (value && typeof value.scheme === "string") return Uri.from(value);
  throw new TypeError("expected a Uri");
}

// ---------------------------------------------------------------------------
// Positions and ranges

class Position {
  constructor(line, character) {
    if (typeof line !== "number" || line < 0) throw new Error("Illegal argument: line");
    if (typeof character !== "number" || character < 0) throw new Error("Illegal argument: character");
    this.line = line;
    this.character = character;
  }
  isBefore(o) {
    return this.line < o.line || (this.line === o.line && this.character < o.character);
  }
  isBeforeOrEqual(o) {
    return this.line < o.line || (this.line === o.line && this.character <= o.character);
  }
  isAfter(o) {
    return !this.isBeforeOrEqual(o);
  }
  isAfterOrEqual(o) {
    return !this.isBefore(o);
  }
  isEqual(o) {
    return this.line === o.line && this.character === o.character;
  }
  compareTo(o) {
    if (this.line < o.line) return -1;
    if (this.line > o.line) return 1;
    if (this.character < o.character) return -1;
    if (this.character > o.character) return 1;
    return 0;
  }
  translate(lineDeltaOrChange, characterDelta) {
    let lineDelta = 0;
    let charDelta = 0;
    if (lineDeltaOrChange && typeof lineDeltaOrChange === "object") {
      lineDelta = lineDeltaOrChange.lineDelta || 0;
      charDelta = lineDeltaOrChange.characterDelta || 0;
    } else {
      lineDelta = lineDeltaOrChange || 0;
      charDelta = characterDelta || 0;
    }
    if (lineDelta === 0 && charDelta === 0) return this;
    return new Position(this.line + lineDelta, this.character + charDelta);
  }
  with(lineOrChange, character) {
    let line = this.line;
    let ch = this.character;
    if (lineOrChange && typeof lineOrChange === "object") {
      if (lineOrChange.line !== undefined) line = lineOrChange.line;
      if (lineOrChange.character !== undefined) ch = lineOrChange.character;
    } else {
      if (lineOrChange !== undefined) line = lineOrChange;
      if (character !== undefined) ch = character;
    }
    if (line === this.line && ch === this.character) return this;
    return new Position(line, ch);
  }
  toJSON() {
    return { line: this.line, character: this.character };
  }
}

function asPosition(v) {
  return v instanceof Position ? v : new Position(v.line, v.character);
}

class Range {
  constructor(a, b, c, d) {
    let start;
    let end;
    if (typeof a === "number") {
      start = new Position(a, b);
      end = new Position(c, d);
    } else {
      start = asPosition(a);
      end = asPosition(b);
    }
    if (start.isAfter(end)) {
      const t = start;
      start = end;
      end = t;
    }
    this.start = start;
    this.end = end;
  }
  get isEmpty() {
    return this.start.isEqual(this.end);
  }
  get isSingleLine() {
    return this.start.line === this.end.line;
  }
  contains(v) {
    if (v instanceof Range) return this.contains(v.start) && this.contains(v.end);
    return this.start.isBeforeOrEqual(v) && v.isBeforeOrEqual(this.end);
  }
  isEqual(o) {
    return this.start.isEqual(o.start) && this.end.isEqual(o.end);
  }
  intersection(o) {
    const start = this.start.isAfter(o.start) ? this.start : o.start;
    const end = this.end.isBefore(o.end) ? this.end : o.end;
    if (start.isAfter(end)) return undefined;
    return new Range(start, end);
  }
  union(o) {
    if (this.contains(o)) return this;
    if (o.contains(this)) return o;
    return new Range(this.start.isBefore(o.start) ? this.start : o.start, this.end.isAfter(o.end) ? this.end : o.end);
  }
  with(startOrChange, end) {
    let s = this.start;
    let e = this.end;
    if (startOrChange && typeof startOrChange === "object" && !(startOrChange instanceof Position)) {
      if (startOrChange.start) s = startOrChange.start;
      if (startOrChange.end) e = startOrChange.end;
    } else {
      if (startOrChange) s = startOrChange;
      if (end) e = end;
    }
    if (s === this.start && e === this.end) return this;
    return new Range(s, e);
  }
  toJSON() {
    return [this.start, this.end];
  }
}

class Selection extends Range {
  constructor(a, b, c, d) {
    let anchor;
    let active;
    if (typeof a === "number") {
      anchor = new Position(a, b);
      active = new Position(c, d);
    } else {
      anchor = asPosition(a);
      active = asPosition(b);
    }
    super(anchor, active);
    this.anchor = anchor;
    this.active = active;
  }
  get isReversed() {
    return this.anchor.isAfter(this.active);
  }
}

class Location {
  constructor(uri, rangeOrPosition) {
    this.uri = uri;
    if (rangeOrPosition instanceof Range) this.range = rangeOrPosition;
    else if (rangeOrPosition instanceof Position) this.range = new Range(rangeOrPosition, rangeOrPosition);
    else if (rangeOrPosition) this.range = new Range(rangeOrPosition.start, rangeOrPosition.end);
    else this.range = undefined;
  }
}

// ---------------------------------------------------------------------------
// Enums, with TypeScript's reverse mapping (Kind[0] === "Text") like the real ones.

function makeEnum(values) {
  const e = {};
  for (const k of Object.keys(values)) {
    e[k] = values[k];
    if (typeof values[k] === "number" && !(values[k] in e)) e[values[k]] = k;
  }
  return Object.freeze(e);
}

const DiagnosticSeverity = makeEnum({ Error: 0, Warning: 1, Information: 2, Hint: 3 });
const DiagnosticTag = makeEnum({ Unnecessary: 1, Deprecated: 2 });
const CompletionItemKind = makeEnum({
  Text: 0, Method: 1, Function: 2, Constructor: 3, Field: 4, Variable: 5, Class: 6, Interface: 7, Module: 8,
  Property: 9, Unit: 10, Value: 11, Enum: 12, Keyword: 13, Snippet: 14, Color: 15, File: 16, Reference: 17,
  Folder: 18, EnumMember: 19, Constant: 20, Struct: 21, Event: 22, Operator: 23, TypeParameter: 24, User: 25, Issue: 26,
});
const CompletionItemTag = makeEnum({ Deprecated: 1 });
const CompletionTriggerKind = makeEnum({ Invoke: 0, TriggerCharacter: 1, TriggerForIncompleteCompletions: 2 });
const SymbolKind = makeEnum({
  File: 0, Module: 1, Namespace: 2, Package: 3, Class: 4, Method: 5, Property: 6, Field: 7, Constructor: 8, Enum: 9,
  Interface: 10, Function: 11, Variable: 12, Constant: 13, String: 14, Number: 15, Boolean: 16, Array: 17, Object: 18,
  Key: 19, Null: 20, EnumMember: 21, Struct: 22, Event: 23, Operator: 24, TypeParameter: 25,
});
const SymbolTag = makeEnum({ Deprecated: 1 });
const StatusBarAlignment = makeEnum({ Left: 1, Right: 2 });
const ProgressLocation = makeEnum({ SourceControl: 1, Window: 10, Notification: 15 });
const ConfigurationTarget = makeEnum({ Global: 1, Workspace: 2, WorkspaceFolder: 3 });
const EndOfLine = makeEnum({ LF: 1, CRLF: 2 });
const ExtensionMode = makeEnum({ Production: 1, Development: 2, Test: 3 });
const ExtensionKind = makeEnum({ UI: 1, Workspace: 2 });
const LanguageStatusSeverity = makeEnum({ Information: 0, Warning: 1, Error: 2 });
const UIKind = makeEnum({ Desktop: 1, Web: 2 });
const FileType = makeEnum({ Unknown: 0, File: 1, Directory: 2, SymbolicLink: 64 });
const FilePermission = makeEnum({ Readonly: 1 });
const FileChangeType = makeEnum({ Changed: 1, Created: 2, Deleted: 3 });
const TextDocumentSaveReason = makeEnum({ Manual: 1, AfterDelay: 2, FocusOut: 3 });
const TextDocumentChangeReason = makeEnum({ Undo: 1, Redo: 2 });
const CodeActionTriggerKind = makeEnum({ Invoke: 1, Automatic: 2 });
const SignatureHelpTriggerKind = makeEnum({ Invoke: 1, TriggerCharacter: 2, ContentChange: 3 });
const DocumentHighlightKind = makeEnum({ Text: 0, Read: 1, Write: 2 });
const FoldingRangeKind = makeEnum({ Comment: 1, Imports: 2, Region: 3 });
const InlayHintKind = makeEnum({ Type: 1, Parameter: 2 });
const ViewColumn = makeEnum({ Active: -1, Beside: -2, One: 1, Two: 2, Three: 3, Four: 4, Five: 5, Six: 6, Seven: 7, Eight: 8, Nine: 9 });
const TreeItemCollapsibleState = makeEnum({ None: 0, Collapsed: 1, Expanded: 2 });
const TreeItemCheckboxState = makeEnum({ Unchecked: 0, Checked: 1 });
const QuickPickItemKind = makeEnum({ Separator: -1, Default: 0 });
const LogLevel = makeEnum({ Off: 0, Trace: 1, Debug: 2, Info: 3, Warning: 4, Error: 5 });
const ColorThemeKind = makeEnum({ Light: 1, Dark: 2, HighContrast: 3, HighContrastLight: 4 });
const TextEditorRevealType = makeEnum({ Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 });
const TextEditorSelectionChangeKind = makeEnum({ Keyboard: 1, Mouse: 2, Command: 3 });
const TextEditorLineNumbersStyle = makeEnum({ Off: 0, On: 1, Relative: 2, Interval: 3 });
const TextEditorCursorStyle = makeEnum({ Line: 1, Block: 2, Underline: 3, LineThin: 4, BlockOutline: 5, UnderlineThin: 6 });
const OverviewRulerLane = makeEnum({ Left: 1, Center: 2, Right: 4, Full: 7 });
const DecorationRangeBehavior = makeEnum({ OpenOpen: 0, ClosedClosed: 1, OpenClosed: 2, ClosedOpen: 3 });
const IndentAction = makeEnum({ None: 0, Indent: 1, IndentOutdent: 2, Outdent: 3 });
const EnvironmentVariableMutatorType = makeEnum({ Replace: 1, Append: 2, Prepend: 3 });
const TaskScope = makeEnum({ Global: 1, Workspace: 2 });
const TaskRevealKind = makeEnum({ Always: 1, Silent: 2, Never: 3 });
const TaskPanelKind = makeEnum({ Shared: 1, Dedicated: 2, New: 3 });
const ShellQuoting = makeEnum({ Escape: 1, Strong: 2, Weak: 3 });
const TerminalLocation = makeEnum({ Panel: 1, Editor: 2 });
const TerminalExitReason = makeEnum({ Unknown: 0, Shutdown: 1, Process: 2, User: 3, Extension: 4 });
const TerminalShellExecutionCommandLineConfidence = makeEnum({ Low: 0, Medium: 1, High: 2 });
const DebugConsoleMode = makeEnum({ Separate: 0, MergeWithParent: 1 });
const DebugConfigurationProviderTriggerKind = makeEnum({ Initial: 1, Dynamic: 2 });
const CommentMode = makeEnum({ Editing: 0, Preview: 1 });
const CommentThreadCollapsibleState = makeEnum({ Collapsed: 0, Expanded: 1 });
const CommentThreadState = makeEnum({ Unresolved: 0, Resolved: 1 });
const NotebookCellKind = makeEnum({ Markup: 1, Code: 2 });
const NotebookCellStatusBarAlignment = makeEnum({ Left: 1, Right: 2 });
const NotebookControllerAffinity = makeEnum({ Default: 1, Preferred: 2 });
const NotebookEditorRevealType = makeEnum({ Default: 0, InCenter: 1, InCenterIfOutsideViewport: 2, AtTop: 3 });
const InlineCompletionTriggerKind = makeEnum({ Invoke: 0, Automatic: 1 });
const SourceControlInputBoxValidationType = makeEnum({ Error: 0, Warning: 1, Information: 2 });
const TestRunProfileKind = makeEnum({ Run: 1, Debug: 2, Coverage: 3 });
const LanguageModelChatMessageRole = makeEnum({ User: 1, Assistant: 2 });
const LanguageModelChatToolMode = makeEnum({ Auto: 1, Required: 2 });
const ChatResultFeedbackKind = makeEnum({ Unhelpful: 0, Helpful: 1 });
const ChatLocation = makeEnum({ Panel: 1, Terminal: 2, Notebook: 3, Editor: 4 });
const ExternalUriOpenerPriority = makeEnum({ None: 0, Option: 1, Default: 2, Preferred: 3 });
const PortAutoForwardAction = makeEnum({ Notify: 1, OpenBrowser: 2, OpenPreview: 3, Silent: 4, Ignore: 5 });
const TerminalOutputAnchor = makeEnum({ Top: 0, Bottom: 1 });
const TerminalQuickFixType = makeEnum({ TerminalCommand: 0, Opener: 1, Command: 3 });
const TabInputTerminalKind = makeEnum({});

// ---------------------------------------------------------------------------
// Plain value classes.

class Disposable {
  constructor(callOnDispose) {
    this._call = typeof callOnDispose === "function" ? callOnDispose : null;
  }
  static from(...disposables) {
    return new Disposable(() => {
      for (const d of disposables) {
        try {
          if (d && typeof d.dispose === "function") d.dispose();
        } catch (err) {
          log("error", "dispose failed: " + describe(err));
        }
      }
    });
  }
  dispose() {
    const fn = this._call;
    this._call = null;
    if (fn) fn();
  }
}

class EventEmitter {
  constructor() {
    this._listeners = new Set();
    this.event = (listener, thisArgs, disposables) => {
      const entry = [listener, thisArgs];
      this._listeners.add(entry);
      const d = new Disposable(() => this._listeners.delete(entry));
      if (Array.isArray(disposables)) disposables.push(d);
      return d;
    };
  }
  fire(data) {
    for (const [listener, thisArgs] of Array.from(this._listeners)) {
      try {
        const r = listener.call(thisArgs, data);
        if (r && typeof r.then === "function") r.catch((err) => log("error", "event listener failed: " + describe(err)));
      } catch (err) {
        log("error", "event listener failed: " + describe(err));
      }
    }
  }
  dispose() {
    this._listeners.clear();
  }
}

class CancellationError extends Error {
  constructor() {
    super("Canceled");
    this.name = "Canceled";
  }
}

class CancellationTokenSource {
  constructor(parent) {
    const emitter = new EventEmitter();
    let cancelled = false;
    this._emitter = emitter;
    this._parentSub = parent ? parent.onCancellationRequested(() => this.cancel()) : null;
    this.token = {
      get isCancellationRequested() {
        return cancelled;
      },
      onCancellationRequested: emitter.event,
    };
    this._setCancelled = () => {
      cancelled = true;
    };
  }
  cancel() {
    if (this.token.isCancellationRequested) return;
    this._setCancelled();
    this._emitter.fire(undefined);
  }
  dispose(cancel) {
    if (cancel) this.cancel();
    if (this._parentSub) this._parentSub.dispose();
    this._emitter.dispose();
  }
}

class TextEdit {
  constructor(range, newText) {
    this.range = range;
    this.newText = newText;
  }
  static replace(range, newText) {
    return new TextEdit(range, newText);
  }
  static insert(position, newText) {
    return new TextEdit(new Range(position, position), newText);
  }
  static delete(range) {
    return new TextEdit(range, "");
  }
  static setEndOfLine(eol) {
    const e = new TextEdit(new Range(0, 0, 0, 0), "");
    e.newEol = eol;
    return e;
  }
}

class SnippetTextEdit {
  constructor(range, snippet) {
    this.range = range;
    this.snippet = snippet;
  }
  static replace(range, snippet) {
    return new SnippetTextEdit(range, snippet);
  }
  static insert(position, snippet) {
    return new SnippetTextEdit(new Range(position, position), snippet);
  }
}

class WorkspaceEdit {
  constructor() {
    this._text = new Map(); // uri string -> { uri, edits }
    this._files = []; // { kind, uri, newUri, options }
  }
  get size() {
    return this._text.size + this._files.length;
  }
  _entry(uri) {
    const key = uri.toString();
    let e = this._text.get(key);
    if (!e) {
      e = { uri, edits: [] };
      this._text.set(key, e);
    }
    return e;
  }
  replace(uri, range, newText) {
    this._entry(uri).edits.push(new TextEdit(range, newText));
  }
  insert(uri, position, newText) {
    this.replace(uri, new Range(position, position), newText);
  }
  delete(uri, range) {
    this.replace(uri, range, "");
  }
  has(uri) {
    return this._text.has(uri.toString());
  }
  set(uri, edits) {
    const key = uri.toString();
    if (!edits || edits.length === 0) {
      this._text.delete(key);
      return;
    }
    const list = [];
    for (const e of edits) {
      // Edits may come as [edit, metadata] pairs.
      const edit = Array.isArray(e) ? e[0] : e;
      if (edit) list.push(edit);
    }
    this._text.set(key, { uri, edits: list });
  }
  get(uri) {
    const e = this._text.get(uri.toString());
    return e ? e.edits.slice() : [];
  }
  entries() {
    return Array.from(this._text.values()).map((e) => [e.uri, e.edits.slice()]);
  }
  createFile(uri, options) {
    this._files.push({ kind: "create", uri, options });
  }
  deleteFile(uri, options) {
    this._files.push({ kind: "delete", uri, options });
  }
  renameFile(oldUri, newUri, options) {
    this._files.push({ kind: "rename", uri: oldUri, newUri, options });
  }
}

class Diagnostic {
  constructor(range, message, severity) {
    this.range = range;
    this.message = message;
    this.severity = severity === undefined ? DiagnosticSeverity.Error : severity;
    this.source = undefined;
    this.code = undefined;
    this.relatedInformation = undefined;
    this.tags = undefined;
  }
}

class DiagnosticRelatedInformation {
  constructor(location, message) {
    this.location = location;
    this.message = message;
  }
}

class MarkdownString {
  constructor(value, supportThemeIcons) {
    this.value = value || "";
    this.isTrusted = undefined;
    this.supportThemeIcons = supportThemeIcons;
    this.supportHtml = undefined;
    this.baseUri = undefined;
  }
  appendText(value) {
    this.value += String(value).replace(/[\\`*_{}[\]()#+\-.!~<>]/g, "\\$&").replace(/\n/g, "\n\n");
    return this;
  }
  appendMarkdown(value) {
    this.value += value;
    return this;
  }
  appendCodeblock(code, language) {
    this.value += "\n```" + (language || "") + "\n" + code + "\n```\n";
    return this;
  }
}

class SnippetString {
  constructor(value) {
    this.value = value || "";
    this._tabstop = 1;
  }
  static _escape(v) {
    return String(v).replace(/\$|}|\\/g, "\\$&");
  }
  appendText(string) {
    this.value += SnippetString._escape(string);
    return this;
  }
  appendTabstop(number) {
    this.value += "$" + (number === undefined ? this._tabstop++ : number);
    return this;
  }
  appendPlaceholder(value, number) {
    const n = number === undefined ? this._tabstop++ : number;
    if (typeof value === "function") {
      const nested = new SnippetString();
      nested._tabstop = this._tabstop;
      value(nested);
      this._tabstop = nested._tabstop;
      value = nested.value;
    } else {
      value = SnippetString._escape(value);
    }
    this.value += "${" + n + ":" + value + "}";
    return this;
  }
  appendChoice(values, number) {
    const n = number === undefined ? this._tabstop++ : number;
    this.value += "${" + n + "|" + values.map((v) => String(v).replace(/[|\\,]/g, "\\$&")).join(",") + "|}";
    return this;
  }
  appendVariable(name, defaultValue) {
    if (typeof defaultValue === "function") {
      const nested = new SnippetString();
      nested._tabstop = this._tabstop;
      defaultValue(nested);
      this._tabstop = nested._tabstop;
      defaultValue = nested.value;
    } else if (defaultValue !== undefined) {
      defaultValue = SnippetString._escape(defaultValue);
    }
    this.value += defaultValue !== undefined && defaultValue !== "" ? "${" + name + ":" + defaultValue + "}" : "${" + name + "}";
    return this;
  }
}

class CompletionItem {
  constructor(label, kind) {
    this.label = label;
    this.kind = kind;
  }
}

class CompletionList {
  constructor(items, isIncomplete) {
    this.items = items || [];
    this.isIncomplete = !!isIncomplete;
  }
}

class Hover {
  constructor(contents, range) {
    this.contents = Array.isArray(contents) ? contents : [contents];
    this.range = range;
  }
}

class SymbolInformation {
  constructor(name, kind, rangeOrContainer, locationOrUri, containerName) {
    this.name = name;
    this.kind = kind;
    if (rangeOrContainer instanceof Range) {
      // Deprecated (name, kind, range, uri, containerName) form.
      this.location = new Location(locationOrUri, rangeOrContainer);
      this.containerName = containerName;
    } else {
      this.containerName = rangeOrContainer;
      this.location = locationOrUri;
    }
  }
}

class DocumentSymbol {
  constructor(name, detail, kind, range, selectionRange) {
    this.name = name;
    this.detail = detail;
    this.kind = kind;
    this.range = range;
    this.selectionRange = selectionRange;
    this.children = [];
  }
}

class CodeActionKind {
  constructor(value) {
    this.value = value;
  }
  append(parts) {
    return new CodeActionKind(this.value ? this.value + "." + parts : parts);
  }
  intersects(other) {
    return this.contains(other) || other.contains(this);
  }
  contains(other) {
    return this.value === other.value || other.value.startsWith(this.value + ".");
  }
}
CodeActionKind.Empty = new CodeActionKind("");
CodeActionKind.QuickFix = new CodeActionKind("quickfix");
CodeActionKind.Refactor = new CodeActionKind("refactor");
CodeActionKind.RefactorExtract = new CodeActionKind("refactor.extract");
CodeActionKind.RefactorInline = new CodeActionKind("refactor.inline");
CodeActionKind.RefactorMove = new CodeActionKind("refactor.move");
CodeActionKind.RefactorRewrite = new CodeActionKind("refactor.rewrite");
CodeActionKind.Source = new CodeActionKind("source");
CodeActionKind.SourceOrganizeImports = new CodeActionKind("source.organizeImports");
CodeActionKind.SourceFixAll = new CodeActionKind("source.fixAll");
CodeActionKind.Notebook = new CodeActionKind("notebook");

class CodeAction {
  constructor(title, kind) {
    this.title = title;
    this.kind = kind;
  }
}

class Command {
  constructor(title, command, args) {
    this.title = title;
    this.command = command;
    this.arguments = args;
  }
}

class RelativePattern {
  constructor(base, pattern) {
    if (typeof base === "string") this.baseUri = Uri.file(base);
    else if (base instanceof Uri) this.baseUri = base;
    else if (base && base.uri) this.baseUri = base.uri;
    else throw new Error("base must be a string, Uri or WorkspaceFolder");
    this.base = this.baseUri.fsPath;
    this.pattern = pattern;
  }
}

class ThemeColor {
  constructor(id) {
    this.id = id;
  }
}

class ThemeIcon {
  constructor(id, color) {
    this.id = id;
    this.color = color;
  }
}
ThemeIcon.File = new ThemeIcon("file");
ThemeIcon.Folder = new ThemeIcon("folder");

class SignatureHelp {
  constructor() {
    this.signatures = [];
    this.activeSignature = 0;
    this.activeParameter = 0;
  }
}

class SignatureInformation {
  constructor(label, documentation) {
    this.label = label;
    this.documentation = documentation;
    this.parameters = [];
    this.activeParameter = undefined;
  }
}

class ParameterInformation {
  constructor(label, documentation) {
    this.label = label;
    this.documentation = documentation;
  }
}

class FileSystemError extends Error {
  constructor(messageOrUri, code) {
    super(messageOrUri instanceof Uri ? messageOrUri.toString() : messageOrUri || "");
    this.name = "FileSystemError";
    this.code = code || "Unknown";
  }
  static FileNotFound(u) {
    return new FileSystemError(u, "FileNotFound");
  }
  static FileExists(u) {
    return new FileSystemError(u, "FileExists");
  }
  static FileNotADirectory(u) {
    return new FileSystemError(u, "FileNotADirectory");
  }
  static FileIsADirectory(u) {
    return new FileSystemError(u, "FileIsADirectory");
  }
  static NoPermissions(u) {
    return new FileSystemError(u, "NoPermissions");
  }
  static Unavailable(u) {
    return new FileSystemError(u, "Unavailable");
  }
}

class TreeItem {
  constructor(label, collapsibleState) {
    if (label instanceof Uri) this.resourceUri = label;
    else this.label = label;
    this.collapsibleState = collapsibleState === undefined ? TreeItemCollapsibleState.None : collapsibleState;
  }
}

class CodeLens {
  constructor(range, command) {
    this.range = range;
    this.command = command;
  }
  get isResolved() {
    return !!this.command;
  }
}

class DocumentLink {
  constructor(range, target) {
    this.range = range;
    this.target = target;
  }
}

class DocumentHighlight {
  constructor(range, kind) {
    this.range = range;
    this.kind = kind === undefined ? DocumentHighlightKind.Text : kind;
  }
}

class FoldingRange {
  constructor(start, end, kind) {
    this.start = start;
    this.end = end;
    this.kind = kind;
  }
}

class SemanticTokensLegend {
  constructor(tokenTypes, tokenModifiers) {
    this.tokenTypes = tokenTypes;
    this.tokenModifiers = tokenModifiers || [];
  }
}

class SemanticTokensBuilder {
  constructor(legend) {
    this._legend = legend;
    this._data = [];
  }
  push() {
    // Tokens are never requested by the host, so building them is pointless.
  }
  build(resultId) {
    return { resultId, data: new Uint32Array(0) };
  }
}

class TelemetryTrustedValue {
  constructor(value) {
    this.value = value;
  }
}

// Constructors that only carry data: positional arguments become fields.
function dataClass(name, fields) {
  const C = class {
    constructor(...args) {
      fields.forEach((f, i) => {
        this[f] = args[i];
      });
    }
  };
  Object.defineProperty(C, "name", { value: name });
  return C;
}

const InlayHint = dataClass("InlayHint", ["position", "label", "kind"]);
const InlayHintLabelPart = dataClass("InlayHintLabelPart", ["value"]);
const SelectionRange = dataClass("SelectionRange", ["range", "parent"]);
const Color = dataClass("Color", ["red", "green", "blue", "alpha"]);
const ColorInformation = dataClass("ColorInformation", ["range", "color"]);
const ColorPresentation = dataClass("ColorPresentation", ["label"]);
const CallHierarchyItem = dataClass("CallHierarchyItem", ["kind", "name", "detail", "uri", "range", "selectionRange"]);
const CallHierarchyIncomingCall = dataClass("CallHierarchyIncomingCall", ["from", "fromRanges"]);
const CallHierarchyOutgoingCall = dataClass("CallHierarchyOutgoingCall", ["to", "fromRanges"]);
const TypeHierarchyItem = dataClass("TypeHierarchyItem", ["kind", "name", "detail", "uri", "range", "selectionRange"]);
const InlineCompletionItem = dataClass("InlineCompletionItem", ["insertText", "range", "command"]);
const InlineCompletionList = dataClass("InlineCompletionList", ["items"]);
const EvaluatableExpression = dataClass("EvaluatableExpression", ["range", "expression"]);
const InlineValueText = dataClass("InlineValueText", ["range", "text"]);
const InlineValueVariableLookup = dataClass("InlineValueVariableLookup", ["range", "variableName", "caseSensitiveLookup"]);
const InlineValueEvaluatableExpression = dataClass("InlineValueEvaluatableExpression", ["range", "expression"]);
const LinkedEditingRanges = dataClass("LinkedEditingRanges", ["ranges", "wordPattern"]);
const SemanticTokens = dataClass("SemanticTokens", ["data", "resultId"]);
const SemanticTokensEdit = dataClass("SemanticTokensEdit", ["start", "deleteCount", "data"]);
const SemanticTokensEdits = dataClass("SemanticTokensEdits", ["edits", "resultId"]);
const DocumentDropEdit = dataClass("DocumentDropEdit", ["insertText", "title", "kind"]);
const DocumentPasteEdit = dataClass("DocumentPasteEdit", ["insertText", "title", "kind"]);
const DocumentDropOrPasteEditKind = CodeActionKind;
const DocumentPasteEditKind = CodeActionKind;
const DataTransferItem = dataClass("DataTransferItem", ["value"]);
DataTransferItem.prototype.asString = function () {
  return Promise.resolve(typeof this.value === "string" ? this.value : JSON.stringify(this.value));
};
DataTransferItem.prototype.asFile = function () {
  return undefined;
};
class DataTransfer {
  constructor() {
    this._items = new Map();
  }
  get(mime) {
    return this._items.get(mime);
  }
  set(mime, value) {
    this._items.set(mime, value);
  }
  forEach(cb, thisArg) {
    for (const [k, v] of this._items) cb.call(thisArg, v, k, this);
  }
  [Symbol.iterator]() {
    return this._items[Symbol.iterator]();
  }
}
const FileDecoration = dataClass("FileDecoration", ["badge", "tooltip", "color"]);
const TerminalLink = dataClass("TerminalLink", ["startIndex", "length", "tooltip"]);
const TerminalProfile = dataClass("TerminalProfile", ["options"]);
const TerminalQuickFixOpener = dataClass("TerminalQuickFixOpener", ["uri"]);
const TerminalQuickFixTerminalCommand = dataClass("TerminalQuickFixTerminalCommand", ["terminalCommand", "shouldExecute"]);
const Task = dataClass("Task", ["definition", "scope", "name", "source", "execution", "problemMatchers"]);
const TaskGroup = dataClass("TaskGroup", ["id", "label"]);
TaskGroup.Clean = new TaskGroup("clean", "Clean");
TaskGroup.Build = new TaskGroup("build", "Build");
TaskGroup.Rebuild = new TaskGroup("rebuild", "Rebuild");
TaskGroup.Test = new TaskGroup("test", "Test");
const ProcessExecution = dataClass("ProcessExecution", ["process", "args", "options"]);
const ShellExecution = dataClass("ShellExecution", ["commandLine", "args", "options"]);
const CustomExecution = dataClass("CustomExecution", ["callback"]);
const Breakpoint = dataClass("Breakpoint", ["enabled", "condition", "hitCondition", "logMessage"]);
const SourceBreakpoint = dataClass("SourceBreakpoint", ["location", "enabled", "condition", "hitCondition", "logMessage"]);
const FunctionBreakpoint = dataClass("FunctionBreakpoint", ["functionName", "enabled", "condition", "hitCondition", "logMessage"]);
const DebugAdapterExecutable = dataClass("DebugAdapterExecutable", ["command", "args", "options"]);
const DebugAdapterServer = dataClass("DebugAdapterServer", ["port", "host"]);
const DebugAdapterNamedPipeServer = dataClass("DebugAdapterNamedPipeServer", ["path"]);
const DebugAdapterInlineImplementation = dataClass("DebugAdapterInlineImplementation", ["implementation"]);
const DebugThread = dataClass("DebugThread", ["session", "threadId"]);
const DebugStackFrame = dataClass("DebugStackFrame", ["session", "threadId", "frameId"]);
const TestTag = dataClass("TestTag", ["id"]);
const TestMessage = dataClass("TestMessage", ["message"]);
TestMessage.diff = (message, expected, actual) => Object.assign(new TestMessage(message), { expectedOutput: expected, actualOutput: actual });
const TestRunRequest = dataClass("TestRunRequest", ["include", "exclude", "profile", "continuous", "preserveFocus"]);
const TestCoverageCount = dataClass("TestCoverageCount", ["covered", "total"]);
const FileCoverage = dataClass("FileCoverage", ["uri", "statementCoverage", "branchCoverage", "declarationCoverage", "includesTests"]);
const StatementCoverage = dataClass("StatementCoverage", ["executed", "location", "branches"]);
const BranchCoverage = dataClass("BranchCoverage", ["executed", "location", "label"]);
const DeclarationCoverage = dataClass("DeclarationCoverage", ["name", "executed", "location"]);
const NotebookRange = dataClass("NotebookRange", ["start", "end"]);
const NotebookCellData = dataClass("NotebookCellData", ["kind", "value", "languageId"]);
const NotebookData = dataClass("NotebookData", ["cells"]);
const NotebookCellOutput = dataClass("NotebookCellOutput", ["items", "metadata"]);
const NotebookCellOutputItem = dataClass("NotebookCellOutputItem", ["data", "mime"]);
NotebookCellOutputItem.text = (value, mime) => new NotebookCellOutputItem(Buffer.from(String(value)), mime || "text/plain");
NotebookCellOutputItem.json = (value, mime) => new NotebookCellOutputItem(Buffer.from(JSON.stringify(value)), mime || "text/x-json");
NotebookCellOutputItem.stdout = (value) => new NotebookCellOutputItem(Buffer.from(String(value)), "application/vnd.code.notebook.stdout");
NotebookCellOutputItem.stderr = (value) => new NotebookCellOutputItem(Buffer.from(String(value)), "application/vnd.code.notebook.stderr");
NotebookCellOutputItem.error = (value) => new NotebookCellOutputItem(Buffer.from(JSON.stringify({ name: value && value.name, message: value && value.message })), "application/vnd.code.notebook.error");
const NotebookEdit = dataClass("NotebookEdit", ["range", "newCells"]);
NotebookEdit.replaceCells = (range, newCells) => new NotebookEdit(range, newCells);
NotebookEdit.insertCells = (index, newCells) => new NotebookEdit(new NotebookRange(index, index), newCells);
NotebookEdit.deleteCells = (range) => new NotebookEdit(range, []);
NotebookEdit.updateCellMetadata = (index, metadata) => Object.assign(new NotebookEdit(new NotebookRange(index, index + 1), []), { newCellMetadata: metadata });
NotebookEdit.updateNotebookMetadata = (metadata) => Object.assign(new NotebookEdit(new NotebookRange(0, 0), []), { newNotebookMetadata: metadata });
const NotebookRendererScript = dataClass("NotebookRendererScript", ["uri", "provides"]);
const TabInputText = dataClass("TabInputText", ["uri"]);
const TabInputTextDiff = dataClass("TabInputTextDiff", ["original", "modified"]);
const TabInputCustom = dataClass("TabInputCustom", ["uri", "viewType"]);
const TabInputWebview = dataClass("TabInputWebview", ["viewType"]);
const TabInputNotebook = dataClass("TabInputNotebook", ["uri", "notebookType"]);
const TabInputNotebookDiff = dataClass("TabInputNotebookDiff", ["original", "modified", "notebookType"]);
const TabInputTerminal = dataClass("TabInputTerminal", []);
const QuickInputButtons = { Back: { iconPath: new ThemeIcon("arrow-left"), tooltip: "Back" } };
const ChatRequestTurn = dataClass("ChatRequestTurn", ["prompt", "command", "references", "participant", "toolReferences"]);
const ChatResponseTurn = dataClass("ChatResponseTurn", ["response", "result", "participant", "command"]);
const ChatResponseMarkdownPart = dataClass("ChatResponseMarkdownPart", ["value"]);
const ChatResponseFileTreePart = dataClass("ChatResponseFileTreePart", ["value", "baseUri"]);
const ChatResponseAnchorPart = dataClass("ChatResponseAnchorPart", ["value", "title"]);
const ChatResponseProgressPart = dataClass("ChatResponseProgressPart", ["value"]);
const ChatResponseReferencePart = dataClass("ChatResponseReferencePart", ["value", "iconPath"]);
const ChatResponseCommandButtonPart = dataClass("ChatResponseCommandButtonPart", ["value"]);
const LanguageModelChatMessage = dataClass("LanguageModelChatMessage", ["role", "content", "name"]);
LanguageModelChatMessage.User = (content, name) => new LanguageModelChatMessage(LanguageModelChatMessageRole.User, content, name);
LanguageModelChatMessage.Assistant = (content, name) => new LanguageModelChatMessage(LanguageModelChatMessageRole.Assistant, content, name);
const LanguageModelTextPart = dataClass("LanguageModelTextPart", ["value"]);
const LanguageModelToolCallPart = dataClass("LanguageModelToolCallPart", ["callId", "name", "input"]);
const LanguageModelToolResultPart = dataClass("LanguageModelToolResultPart", ["callId", "content"]);
const LanguageModelToolResult = dataClass("LanguageModelToolResult", ["content"]);
const LanguageModelPromptTsxPart = dataClass("LanguageModelPromptTsxPart", ["value"]);
class LanguageModelError extends Error {
  constructor(message) {
    super(message);
    this.name = "LanguageModelError";
    this.code = "Unknown";
  }
  static NoPermissions(m) {
    return Object.assign(new LanguageModelError(m), { code: "NoPermissions" });
  }
  static Blocked(m) {
    return Object.assign(new LanguageModelError(m), { code: "Blocked" });
  }
  static NotFound(m) {
    return Object.assign(new LanguageModelError(m), { code: "NotFound" });
  }
}
const McpStdioServerDefinition = dataClass("McpStdioServerDefinition", ["label", "command", "args", "env", "version"]);
const McpHttpServerDefinition = dataClass("McpHttpServerDefinition", ["label", "uri", "headers", "version"]);
const PortAttributes = dataClass("PortAttributes", ["autoForwardAction"]);
const ShellExecutionOptions = dataClass("ShellExecutionOptions", []);

// ---------------------------------------------------------------------------
// LSP conversions, shared with host.js.

function toLspPosition(p) {
  return { line: p.line, character: p.character };
}
function toLspRange(r) {
  return { start: toLspPosition(r.start), end: toLspPosition(r.end) };
}
function fromLspPosition(p) {
  return new Position(p.line, p.character);
}
function fromLspRange(r) {
  return new Range(fromLspPosition(r.start), fromLspPosition(r.end));
}
function uriString(u) {
  return u instanceof Uri ? u.toString() : String(u);
}

function toLspTextEdit(e) {
  return { range: toLspRange(e.range), newText: e.newText === undefined ? "" : String(e.newText) };
}

function toLspTextEdits(edits) {
  if (!Array.isArray(edits)) return null;
  return edits.filter((e) => e && e.range).map(toLspTextEdit);
}

function toMarkup(value, plainStringIsMarkdown) {
  if (value === undefined || value === null) return undefined;
  if (value instanceof MarkdownString) return { kind: "markdown", value: value.value };
  if (typeof value === "string") return { kind: plainStringIsMarkdown ? "markdown" : "plaintext", value };
  if (typeof value === "object" && typeof value.value === "string") {
    if (value.language) return { kind: "markdown", value: "```" + value.language + "\n" + value.value + "\n```" };
    return { kind: value.kind === "plaintext" ? "plaintext" : "markdown", value: value.value };
  }
  return { kind: "plaintext", value: String(value) };
}

function toLspHover(h) {
  if (!h) return null;
  const parts = (Array.isArray(h.contents) ? h.contents : [h.contents]).map((c) => toMarkup(c, true)).filter(Boolean);
  if (!parts.length) return null;
  const out = { contents: { kind: "markdown", value: parts.map((p) => p.value).join("\n\n") } };
  if (h.range) out.range = toLspRange(h.range);
  return out;
}

function toLspCommand(c) {
  if (!c) return undefined;
  const out = { title: c.title || "", command: c.command };
  if (c.arguments) out.arguments = c.arguments;
  return out;
}

function toLspCompletionItem(item, data) {
  const label = typeof item.label === "string" ? item.label : item.label && item.label.label;
  const out = { label: String(label === undefined ? "" : label) };
  if (item.label && typeof item.label === "object") {
    const details = {};
    if (item.label.detail) details.detail = item.label.detail;
    if (item.label.description) details.description = item.label.description;
    if (Object.keys(details).length) out.labelDetails = details;
  }
  if (typeof item.kind === "number") out.kind = item.kind >= 0 && item.kind <= 24 ? item.kind + 1 : 1;
  if (Array.isArray(item.tags) && item.tags.length) out.tags = item.tags.slice();
  if (item.detail !== undefined) out.detail = String(item.detail);
  const doc = toMarkup(item.documentation, false);
  if (doc) out.documentation = doc;
  if (item.sortText !== undefined) out.sortText = item.sortText;
  if (item.filterText !== undefined) out.filterText = item.filterText;
  if (item.preselect) out.preselect = true;
  if (item.keepWhitespace) out.insertTextMode = 1;
  let insertText;
  if (item.insertText instanceof SnippetString) {
    insertText = item.insertText.value;
    out.insertTextFormat = 2;
  } else if (typeof item.insertText === "string") {
    insertText = item.insertText;
  }
  const newText = insertText === undefined ? out.label : insertText;
  const range = item.range || (item.textEdit && item.textEdit.range);
  if (range instanceof Range) {
    out.textEdit = { range: toLspRange(range), newText };
  } else if (range && range.inserting && range.replacing) {
    out.textEdit = { insert: toLspRange(range.inserting), replace: toLspRange(range.replacing), newText };
  } else if (insertText !== undefined) {
    out.insertText = insertText;
  }
  if (Array.isArray(item.additionalTextEdits)) out.additionalTextEdits = toLspTextEdits(item.additionalTextEdits);
  if (Array.isArray(item.commitCharacters)) out.commitCharacters = item.commitCharacters.slice();
  if (item.command) out.command = toLspCommand(item.command);
  if (data) out.data = data;
  return out;
}

function toLspLocation(loc) {
  if (!loc) return null;
  if (loc.targetUri) {
    const out = { targetUri: uriString(loc.targetUri), targetRange: toLspRange(loc.targetRange) };
    out.targetSelectionRange = toLspRange(loc.targetSelectionRange || loc.targetRange);
    if (loc.originSelectionRange) out.originSelectionRange = toLspRange(loc.originSelectionRange);
    return out;
  }
  return { uri: uriString(loc.uri), range: toLspRange(loc.range) };
}

function toLspLocations(result) {
  if (!result) return null;
  const list = Array.isArray(result) ? result : [result];
  return list.map(toLspLocation).filter(Boolean);
}

function toLspSymbolKind(kind) {
  return typeof kind === "number" && kind >= 0 && kind <= 25 ? kind + 1 : 1;
}

function toLspDocumentSymbol(s) {
  const out = { name: String(s.name), kind: toLspSymbolKind(s.kind), range: toLspRange(s.range), selectionRange: toLspRange(s.selectionRange || s.range) };
  if (s.detail) out.detail = s.detail;
  if (Array.isArray(s.tags) && s.tags.length) out.tags = s.tags.slice();
  if (Array.isArray(s.children) && s.children.length) out.children = s.children.map(toLspDocumentSymbol);
  return out;
}

function toLspSymbolInformation(s) {
  const out = { name: String(s.name), kind: toLspSymbolKind(s.kind), location: toLspLocation(s.location) };
  if (s.containerName) out.containerName = s.containerName;
  if (Array.isArray(s.tags) && s.tags.length) out.tags = s.tags.slice();
  return out;
}

function toLspSymbols(result) {
  if (!Array.isArray(result) || !result.length) return null;
  if (result[0] instanceof DocumentSymbol || (result[0] && result[0].selectionRange)) return result.map(toLspDocumentSymbol);
  return result.map(toLspSymbolInformation);
}

function toLspDiagnostic(d) {
  const out = { range: toLspRange(d.range), message: String(d.message) };
  out.severity = typeof d.severity === "number" ? Math.min(4, Math.max(1, d.severity + 1)) : 1;
  if (d.source) out.source = d.source;
  if (d.code !== undefined && d.code !== null) {
    if (typeof d.code === "object") {
      out.code = d.code.value;
      if (d.code.target) out.codeDescription = { href: uriString(d.code.target) };
    } else {
      out.code = d.code;
    }
  }
  if (Array.isArray(d.tags) && d.tags.length) out.tags = d.tags.slice();
  if (Array.isArray(d.relatedInformation) && d.relatedInformation.length) {
    out.relatedInformation = d.relatedInformation.map((r) => ({ location: toLspLocation(r.location), message: String(r.message) }));
  }
  return out;
}

function fromLspDiagnostic(d) {
  const diag = new Diagnostic(fromLspRange(d.range), d.message, typeof d.severity === "number" ? d.severity - 1 : DiagnosticSeverity.Error);
  if (d.source) diag.source = d.source;
  if (d.code !== undefined) diag.code = d.codeDescription ? { value: d.code, target: Uri.parse(d.codeDescription.href) } : d.code;
  if (d.tags) diag.tags = d.tags.slice();
  if (d.relatedInformation) {
    diag.relatedInformation = d.relatedInformation.map(
      (r) => new DiagnosticRelatedInformation(new Location(Uri.parse(r.location.uri), fromLspRange(r.location.range)), r.message)
    );
  }
  return diag;
}

function toLspWorkspaceEdit(we) {
  if (!we) return null;
  const out = {};
  if (we._files.length) {
    // Resource operations need documentChanges; text edits ride along in the same list.
    out.documentChanges = [];
    for (const f of we._files) {
      if (f.kind === "rename") out.documentChanges.push({ kind: "rename", oldUri: uriString(f.uri), newUri: uriString(f.newUri), options: f.options });
      else out.documentChanges.push({ kind: f.kind, uri: uriString(f.uri), options: f.options });
    }
    for (const [uri, edits] of we.entries()) {
      out.documentChanges.push({ textDocument: { uri: uriString(uri), version: null }, edits: toLspTextEdits(edits) });
    }
  } else {
    out.changes = {};
    for (const [uri, edits] of we.entries()) out.changes[uriString(uri)] = toLspTextEdits(edits);
  }
  return out;
}

function toLspCodeAction(a, data) {
  if (!a) return null;
  if (typeof a.command === "string") {
    // A bare Command.
    return { title: a.title || "", command: toLspCommand(a) };
  }
  const out = { title: String(a.title) };
  if (a.kind && a.kind.value) out.kind = a.kind.value;
  if (Array.isArray(a.diagnostics)) out.diagnostics = a.diagnostics.map(toLspDiagnostic);
  if (a.isPreferred) out.isPreferred = true;
  if (a.disabled) out.disabled = { reason: a.disabled.reason || "" };
  if (a.edit) out.edit = toLspWorkspaceEdit(a.edit);
  if (a.command) out.command = toLspCommand(a.command);
  if (data) out.data = data;
  return out;
}

function toLspSignatureHelp(sh) {
  if (!sh || !Array.isArray(sh.signatures)) return null;
  const out = {
    signatures: sh.signatures.map((s) => {
      const sig = { label: String(s.label) };
      const doc = toMarkup(s.documentation, false);
      if (doc) sig.documentation = doc;
      if (Array.isArray(s.parameters)) {
        sig.parameters = s.parameters.map((p) => {
          const param = { label: Array.isArray(p.label) ? p.label.slice() : String(p.label) };
          const pdoc = toMarkup(p.documentation, false);
          if (pdoc) param.documentation = pdoc;
          return param;
        });
      }
      if (typeof s.activeParameter === "number") sig.activeParameter = s.activeParameter;
      return sig;
    }),
  };
  if (typeof sh.activeSignature === "number") out.activeSignature = sh.activeSignature;
  if (typeof sh.activeParameter === "number") out.activeParameter = sh.activeParameter;
  return out;
}

function toLspCodeLens(l, data) {
  const out = { range: toLspRange(l.range) };
  if (l.command) out.command = toLspCommand(l.command);
  if (data) out.data = data;
  return out;
}

function toLspDocumentLink(l, data) {
  const out = { range: toLspRange(l.range) };
  if (l.target) out.target = uriString(l.target);
  if (l.tooltip) out.tooltip = l.tooltip;
  if (data) out.data = data;
  return out;
}

function toLspFoldingRange(f) {
  const out = { startLine: f.start, endLine: f.end };
  if (f.kind) out.kind = ["comment", "imports", "region"][f.kind - 1];
  return out;
}

function toLspDocumentHighlight(h) {
  return { range: toLspRange(h.range), kind: typeof h.kind === "number" ? h.kind + 1 : 1 };
}

// DocumentSelector -> LSP documentSelector for dynamic registration.
function toLspSelector(selector) {
  const list = Array.isArray(selector) ? selector : [selector];
  const out = [];
  for (const s of list) {
    if (typeof s === "string") out.push({ language: s });
    else if (s && typeof s === "object") {
      const f = {};
      if (s.language) f.language = s.language;
      if (s.scheme) f.scheme = s.scheme;
      if (s.pattern instanceof RelativePattern) f.pattern = slashes(path.posix.join(slashes(s.pattern.baseUri.fsPath), s.pattern.pattern));
      else if (typeof s.pattern === "string") f.pattern = slashes(s.pattern);
      if (Object.keys(f).length) out.push(f);
    }
  }
  return out;
}

const convert = {
  toLspPosition, toLspRange, fromLspPosition, fromLspRange, toLspTextEdit, toLspTextEdits, toMarkup, toLspHover,
  toLspCommand, toLspCompletionItem, toLspLocation, toLspLocations, toLspDocumentSymbol, toLspSymbolInformation,
  toLspSymbols, toLspDiagnostic, fromLspDiagnostic, toLspWorkspaceEdit, toLspCodeAction, toLspSignatureHelp,
  toLspCodeLens, toLspDocumentLink, toLspFoldingRange, toLspDocumentHighlight, toLspSelector, uriString,
};

// ---------------------------------------------------------------------------
// Document selectors.

function score(selector, doc) {
  if (Array.isArray(selector)) {
    let best = 0;
    for (const s of selector) best = Math.max(best, score(s, doc));
    return best;
  }
  if (typeof selector === "string") {
    if (selector === "*") return 5;
    return selector === doc.languageId ? 10 : 0;
  }
  if (!selector || typeof selector !== "object") return 0;
  let result = 0;
  if (selector.language) {
    if (selector.language === "*") result = Math.max(result, 5);
    else if (selector.language === doc.languageId) result = 10;
    else return 0;
  }
  if (selector.scheme) {
    if (selector.scheme === "*") result = Math.max(result, 5);
    else if (selector.scheme === doc.uri.scheme) result = 10;
    else return 0;
  }
  if (selector.pattern) {
    if (!matchGlob(selector.pattern, doc.uri.fsPath)) return 0;
    result = 10;
  }
  if (selector.notebookType) return 0;
  return result;
}

// ---------------------------------------------------------------------------
// Client messaging helpers.

let readyResolve;
const ready = new Promise((resolve) => {
  readyResolve = resolve;
});

// While `initialize` is in flight the protocol lets the server send only these to the
// client: window/showMessage, window/logMessage and telemetry/event notifications, and
// the window/showMessageRequest request. Everything else waits for `initialized`.
const EARLY_REQUESTS = new Set(["window/showMessageRequest"]);
const EARLY_NOTIFICATIONS = new Set(["window/showMessage", "window/logMessage", "telemetry/event"]);
const deferredNotifications = [];
let gatedRequests = 0;

function clientRequest(method, params) {
  if (!host.connection) return Promise.reject(new Error("no connection"));
  if (state.initialized || EARLY_REQUESTS.has(method)) return host.connection.sendRequest(method, params);
  // Not allowed yet. host.js is told, because an activate() awaiting this request
  // cannot finish before initialize is answered, and initialize is waiting for it.
  gatedRequests++;
  if (hooks.onGatedRequest) hooks.onGatedRequest(method);
  return ready.then(() => {
    gatedRequests--;
    if (!host.connection) throw new Error("no connection");
    return host.connection.sendRequest(method, params);
  });
}

function clientNotify(method, params) {
  if (!host.connection) return;
  if (state.initialized || EARLY_NOTIFICATIONS.has(method)) host.connection.sendNotification(method, params);
  else deferredNotifications.push({ method, params });
}

function flushDeferredNotifications() {
  for (const n of deferredNotifications.splice(0)) {
    if (host.connection) host.connection.sendNotification(n.method, n.params);
  }
}

const MessageType = { Error: 1, Warning: 2, Info: 3, Log: 4, Debug: 5 };

function showMessage(type, message, rest) {
  let options = {};
  let items = rest;
  if (rest.length && rest[0] && typeof rest[0] === "object" && !("title" in rest[0])) {
    options = rest[0];
    items = rest.slice(1);
  }
  items = items.filter((i) => i !== undefined && i !== null);
  const text = options.detail ? message + "\n" + options.detail : String(message);
  if (!items.length) {
    clientNotify("window/showMessage", { type, message: text });
    return Promise.resolve(undefined);
  }
  const actions = items.map((i) => ({ title: typeof i === "string" ? i : String(i.title) }));
  return clientRequest("window/showMessageRequest", { type, message: text, actions }).then(
    (res) => {
      if (!res || !res.title) return undefined;
      const idx = actions.findIndex((a) => a.title === res.title);
      return idx >= 0 ? items[idx] : undefined;
    },
    (err) => {
      log("warn", "showMessageRequest failed: " + describe(err));
      return undefined;
    }
  );
}

function logMessage(type, message) {
  clientNotify("window/logMessage", { type, message });
}

function showDocument(uri, options) {
  const u = asUri(uri);
  const params = { uri: u.toString(), external: /^https?$/i.test(u.scheme) };
  if (!params.external) {
    if (options && options.selection) params.selection = toLspRange(options.selection);
    params.takeFocus = !(options && options.preserveFocus);
  }
  return clientRequest("window/showDocument", params).then(
    (r) => !!(r && r.success),
    (err) => {
      log("warn", "showDocument failed: " + describe(err));
      return false;
    }
  );
}

// ---------------------------------------------------------------------------
// Registries.

const providers = new Map(); // kind -> entries
const commandsRegistry = new Map(); // id -> { fn, thisArg }
const contexts = new Map(); // setContext keys, kept so getContext-style reads answer
const hooks = { onProviderChange: null, onCommandChange: null, onGatedRequest: null };
let providerSeq = 0;

function registerProvider(kind, selector, provider, options) {
  const entry = { id: kind + "-" + ++providerSeq, kind, selector, provider, options: options || {} };
  let list = providers.get(kind);
  if (!list) {
    list = [];
    providers.set(kind, list);
  }
  list.push(entry);
  log("debug", "registered " + kind + " provider " + entry.id + " for " + JSON.stringify(toLspSelector(selector)));
  if (hooks.onProviderChange) hooks.onProviderChange(kind, entry, true);
  return new Disposable(() => {
    const i = list.indexOf(entry);
    if (i >= 0) list.splice(i, 1);
    log("debug", "disposed " + kind + " provider " + entry.id);
    if (hooks.onProviderChange) hooks.onProviderChange(kind, entry, false);
  });
}

function registerUnrouted(name, selector, provider) {
  unsupported("languages." + name + " (kept, but the host never calls it)");
  return registerProvider("unrouted:" + name, selector, provider);
}

function providersFor(kind, doc) {
  const list = providers.get(kind) || [];
  return list
    .map((e) => ({ entry: e, score: score(e.selector, doc) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .map((x) => x.entry);
}

// ---------------------------------------------------------------------------
// Configuration.

const config = {
  defaults: {},
  stateOverrides: {},
  fileOverrides: {},
  clientSettings: {},
  sections: [],
  merged() {
    return deepMerge(deepMerge(deepMerge(this.defaults, this.stateOverrides), this.fileOverrides), this.clientSettings);
  },
};

function typeDefault(prop) {
  const type = Array.isArray(prop.type) ? prop.type[0] : prop.type;
  switch (type) {
    case "boolean":
      return false;
    case "number":
    case "integer":
      return 0;
    case "string":
      return "";
    case "array":
      return [];
    case "object":
      return {};
    default:
      return null;
  }
}

function loadConfigurationDefaults(pkg) {
  const contributes = (pkg && pkg.contributes) || {};
  const blocks = Array.isArray(contributes.configuration) ? contributes.configuration : contributes.configuration ? [contributes.configuration] : [];
  const defaults = {};
  const sections = new Set();
  for (const block of blocks) {
    const props = (block && block.properties) || {};
    for (const key of Object.keys(props)) {
      const prop = props[key] || {};
      setPath(defaults, key, "default" in prop ? clone(prop.default) : typeDefault(prop));
      sections.add(key.split(".")[0]);
    }
  }
  if (contributes.configurationDefaults) {
    const cd = normalizeSettings(contributes.configurationDefaults);
    for (const k of Object.keys(cd)) {
      if (!(k in defaults)) defaults[k] = cd[k];
    }
  }
  config.defaults = defaults;
  config.sections = Array.from(sections);
}

const configEmitter = new EventEmitter();

function applySettingsLayer(layer, value) {
  const before = flatten(config.merged());
  config[layer] = normalizeSettings(value);
  const after = flatten(config.merged());
  const changed = new Set();
  for (const k of new Set([...Object.keys(before), ...Object.keys(after)])) {
    if (JSON.stringify(before[k]) !== JSON.stringify(after[k])) changed.add(k);
  }
  if (changed.size) {
    log("debug", "configuration changed: " + Array.from(changed).join(", "));
    configEmitter.fire({
      affectsConfiguration(section) {
        for (const k of changed) {
          if (k === section || k.startsWith(section + ".") || section.startsWith(k + ".")) return true;
        }
        return false;
      },
    });
  }
  return changed;
}

function stateConfigFile() {
  return path.join(host.stateDir, "config.json");
}

function makeConfiguration(section, _scope) {
  const merged = config.merged();
  const sub = section ? getPath(merged, section) : merged;
  const obj = {};
  if (isPlainObject(sub)) for (const k of Object.keys(sub)) obj[k] = clone(sub[k]);
  const fullKey = (k) => (section ? section + "." + k : k);
  Object.defineProperties(obj, {
    get: {
      value(key, defaultValue) {
        const v = getPath(merged, fullKey(key));
        return v === undefined ? defaultValue : clone(v);
      },
    },
    has: {
      value(key) {
        return getPath(merged, fullKey(key)) !== undefined;
      },
    },
    inspect: {
      value(key) {
        const k = fullKey(key);
        const d = getPath(config.defaults, k);
        const g = getPath(deepMerge(deepMerge(config.stateOverrides, config.fileOverrides), config.clientSettings), k);
        if (d === undefined && g === undefined) return undefined;
        return { key: k, defaultValue: clone(d), globalValue: clone(g), workspaceValue: undefined, workspaceFolderValue: undefined };
      },
    },
    update: {
      value(key, value, _target, _overrideInLanguage) {
        const next = clone(config.stateOverrides);
        setPath(next, fullKey(key), value);
        writeJsonFile(stateConfigFile(), next);
        applySettingsLayer("stateOverrides", next);
        return Promise.resolve();
      },
    },
  });
  return obj;
}

// Asks the client for every top-level section the extension contributes. Neovim
// answers from vim.lsp.config.settings, null for sections it does not have.
function refreshFromClient() {
  const caps = state.clientCapabilities || {};
  if (!(caps.workspace && caps.workspace.configuration) || !config.sections.length) return Promise.resolve();
  return clientRequest("workspace/configuration", { items: config.sections.map((section) => ({ section })) }).then(
    (result) => {
      if (!Array.isArray(result)) return;
      const next = clone(config.clientSettings);
      config.sections.forEach((section, i) => {
        if (result[i] !== null && result[i] !== undefined) next[section] = deepMerge(next[section] || {}, normalizeSettings(result[i]));
      });
      applySettingsLayer("clientSettings", next);
    },
    (err) => log("warn", "workspace/configuration failed: " + describe(err))
  );
}

// ---------------------------------------------------------------------------
// Diagnostics.

const collections = new Set();
const diagnosticsEmitter = new EventEmitter();

function publishDiagnostics(uri) {
  const key = uri.toString();
  const all = [];
  for (const c of collections) {
    const e = c._map.get(key);
    if (e) all.push(...e.diagnostics);
  }
  clientNotify("textDocument/publishDiagnostics", { uri: key, diagnostics: all.map(toLspDiagnostic) });
  diagnosticsEmitter.fire({ uris: [uri] });
}

class DiagnosticCollection {
  constructor(name) {
    this.name = name;
    this._map = new Map();
    this._disposed = false;
    collections.add(this);
  }
  set(first, diagnostics) {
    if (this._disposed) return;
    if (first instanceof Uri) {
      const key = first.toString();
      if (diagnostics && diagnostics.length) this._map.set(key, { uri: first, diagnostics: diagnostics.slice() });
      else this._map.delete(key);
      publishDiagnostics(first);
      return;
    }
    if (Array.isArray(first)) {
      const touched = new Map();
      for (const [uri, diags] of first) {
        const key = uri.toString();
        if (!touched.has(key)) {
          touched.set(key, uri);
          this._map.delete(key);
        }
        if (diags && diags.length) {
          const e = this._map.get(key) || { uri, diagnostics: [] };
          e.diagnostics.push(...diags);
          this._map.set(key, e);
        }
      }
      for (const uri of touched.values()) publishDiagnostics(uri);
    }
  }
  delete(uri) {
    if (this._map.delete(uri.toString())) publishDiagnostics(uri);
  }
  clear() {
    const uris = Array.from(this._map.values()).map((e) => e.uri);
    this._map.clear();
    for (const u of uris) publishDiagnostics(u);
  }
  forEach(callback, thisArg) {
    for (const e of this._map.values()) callback.call(thisArg, e.uri, e.diagnostics.slice(), this);
  }
  get(uri) {
    const e = this._map.get(uri.toString());
    return e ? e.diagnostics.slice() : undefined;
  }
  has(uri) {
    return this._map.has(uri.toString());
  }
  dispose() {
    if (this._disposed) return;
    this.clear();
    this._disposed = true;
    collections.delete(this);
  }
  [Symbol.iterator]() {
    return Array.from(this._map.values()).map((e) => [e.uri, e.diagnostics.slice()])[Symbol.iterator]();
  }
}

// ---------------------------------------------------------------------------
// Output channels, status bar items, progress.

function createOutputChannel(name, languageIdOrOptions) {
  const isLog = !!(languageIdOrOptions && typeof languageIdOrOptions === "object" && languageIdOrOptions.log);
  let partial = "";
  const emit = (type, text) => {
    for (const line of String(text).split(/\r?\n/)) {
      log("info", "[" + name + "] " + line);
      logMessage(type, "[" + name + "] " + line);
    }
  };
  const level = LogLevel.Info;
  const levelEmitter = new EventEmitter();
  const channel = {
    name,
    append(value) {
      partial += String(value);
      const lines = partial.split(/\r?\n/);
      partial = lines.pop();
      for (const line of lines) emit(MessageType.Log, line);
    },
    appendLine(value) {
      emit(MessageType.Log, partial + String(value));
      partial = "";
    },
    replace(value) {
      partial = "";
      emit(MessageType.Log, value);
    },
    clear() {
      partial = "";
    },
    show() {
      // There is no panel to reveal; the text is already in the log.
    },
    hide() {},
    dispose() {
      if (partial) emit(MessageType.Log, partial);
      partial = "";
    },
  };
  if (isLog) {
    Object.assign(channel, {
      logLevel: level,
      onDidChangeLogLevel: levelEmitter.event,
      trace: (m, ...a) => emit(MessageType.Debug, "[trace] " + fmt(m, a)),
      debug: (m, ...a) => emit(MessageType.Debug, "[debug] " + fmt(m, a)),
      info: (m, ...a) => emit(MessageType.Info, "[info] " + fmt(m, a)),
      warn: (m, ...a) => emit(MessageType.Warning, "[warning] " + fmt(m, a)),
      error: (m, ...a) => emit(MessageType.Error, "[error] " + fmt(m, a)),
    });
  }
  return channel;
}

function fmt(message, args) {
  const parts = [message instanceof Error ? message.stack || message.message : String(message)];
  for (const a of args) {
    if (a instanceof Error) parts.push(a.stack || a.message);
    else if (typeof a === "object") {
      try {
        parts.push(JSON.stringify(a));
      } catch (_) {
        parts.push(String(a));
      }
    } else parts.push(String(a));
  }
  return parts.join(" ");
}

let statusSeq = 0;
function createStatusBarItem(a, b, c) {
  let id;
  let alignment;
  let priority;
  if (typeof a === "string") {
    id = a;
    alignment = b;
    priority = c;
  } else {
    id = "status-" + ++statusSeq;
    alignment = a;
    priority = b;
  }
  let text = "";
  let visible = false;
  let lastSent = null;
  const push = () => {
    if (!visible) return;
    const line = "status bar [" + (item.name || id) + "]: " + text + (item.tooltip ? "  (" + (typeof item.tooltip === "string" ? item.tooltip : item.tooltip.value) + ")" : "");
    if (line === lastSent) return;
    lastSent = line;
    log("info", line);
    logMessage(MessageType.Log, line);
  };
  const item = {
    id,
    alignment: alignment === undefined ? StatusBarAlignment.Left : alignment,
    priority,
    name: undefined,
    tooltip: undefined,
    color: undefined,
    backgroundColor: undefined,
    command: undefined,
    accessibilityInformation: undefined,
    show() {
      visible = true;
      push();
    },
    hide() {
      visible = false;
    },
    dispose() {
      visible = false;
    },
  };
  Object.defineProperty(item, "text", {
    enumerable: true,
    get: () => text,
    set: (v) => {
      text = String(v === undefined ? "" : v);
      push();
    },
  });
  return item;
}

let progressSeq = 0;
const progressSources = new Map(); // token -> CancellationTokenSource, for window/workDoneProgress/cancel

// The task starts at once, as in VS Code. The $/progress frames follow the client's
// answer to window/workDoneProgress/create (which waits for `initialized` when the
// extension is still activating), so a task that awaits nothing else cannot be held
// up by the client, and reports made before `begin` are replayed after it.
function withProgress(options, task) {
  const token = "nvs-progress-" + ++progressSeq;
  const caps = state.clientCapabilities || {};
  const supported = !!(caps.window && caps.window.workDoneProgress);
  const title = (options && options.title) || (host.extension && host.extension.displayName) || "extension";
  const cancellable = !!(options && options.cancellable);
  const cts = new CancellationTokenSource();
  let began = false;
  let ended = false;
  const buffered = [];
  if (supported) {
    progressSources.set(token, cts);
    clientRequest("window/workDoneProgress/create", { token }).then(
      () => {
        began = true;
        clientNotify("$/progress", { token, value: { kind: "begin", title, cancellable } });
        for (const v of buffered.splice(0)) clientNotify("$/progress", { token, value: v });
        if (ended) {
          clientNotify("$/progress", { token, value: { kind: "end" } });
          progressSources.delete(token);
        }
      },
      (err) => {
        log("warn", "progress create failed: " + describe(err));
        progressSources.delete(token);
      }
    );
  }
  let percentage = 0;
  const progress = {
    report(value) {
      if (!value) return;
      if (typeof value.increment === "number") percentage = Math.min(100, percentage + value.increment);
      const v = { kind: "report" };
      if (value.message) v.message = String(value.message);
      if (typeof value.increment === "number") v.percentage = Math.round(percentage);
      if (began) clientNotify("$/progress", { token, value: v });
      else if (supported) buffered.push(v);
      if (value.message && !began) log("info", "progress [" + title + "]: " + value.message);
    },
  };
  return Promise.resolve()
    .then(() => task(progress, cts.token))
    .finally(() => {
      ended = true;
      if (began) {
        clientNotify("$/progress", { token, value: { kind: "end" } });
        progressSources.delete(token);
      }
      cts.dispose();
    });
}

// window/workDoneProgress/cancel from the client: the person dismissed the progress.
function cancelProgress(token) {
  const cts = progressSources.get(token);
  if (cts) cts.cancel();
}

// ---------------------------------------------------------------------------
// File system watchers and searches.

function createFileSystemWatcher(globPattern, ignoreCreateEvents, ignoreChangeEvents, ignoreDeleteEvents) {
  const create = new EventEmitter();
  const change = new EventEmitter();
  const del = new EventEmitter();
  const bases = [];
  if (globPattern instanceof RelativePattern) {
    bases.push({ base: globPattern.baseUri.fsPath, glob: globPattern.pattern });
  } else if (isAbsoluteGlob(String(globPattern))) {
    // Split an absolute glob at its first wildcard segment.
    const parts = slashes(String(globPattern)).split("/");
    const fixed = [];
    while (parts.length && !/[*?{[]/.test(parts[0])) fixed.push(parts.shift());
    bases.push({ base: fixed.join("/") || "/", glob: parts.join("/") || "**" });
  } else {
    for (const f of state.workspaceFolders) bases.push({ base: f.uri.fsPath, glob: String(globPattern) });
  }
  const watchers = [];
  for (const { base, glob } of bases) {
    try {
      const re = globToRegExp(glob);
      const known = new Set();
      const w = fs.watch(base, { recursive: true }, (eventType, filename) => {
        if (!filename) return;
        const rel = slashes(String(filename));
        if (!re.test(rel)) return;
        const full = path.join(base, String(filename));
        const uri = Uri.file(full);
        let exists = false;
        try {
          fs.accessSync(full);
          exists = true;
        } catch (_) {
          exists = false;
        }
        if (!exists) {
          if (known.delete(full) || eventType === "rename") {
            if (!ignoreDeleteEvents) del.fire(uri);
          }
          return;
        }
        if (!known.has(full)) {
          known.add(full);
          if (eventType === "rename") {
            if (!ignoreCreateEvents) create.fire(uri);
            return;
          }
        }
        if (!ignoreChangeEvents) change.fire(uri);
      });
      w.on("error", (err) => log("warn", "watcher error for " + base + ": " + err.message));
      if (typeof w.unref === "function") w.unref();
      watchers.push(w);
    } catch (err) {
      log("warn", "cannot watch " + base + " for " + glob + ": " + err.message);
    }
  }
  return {
    ignoreCreateEvents: !!ignoreCreateEvents,
    ignoreChangeEvents: !!ignoreChangeEvents,
    ignoreDeleteEvents: !!ignoreDeleteEvents,
    onDidCreate: create.event,
    onDidChange: change.event,
    onDidDelete: del.event,
    dispose() {
      for (const w of watchers) {
        try {
          w.close();
        } catch (_) {
          // Already closed.
        }
      }
      create.dispose();
      change.dispose();
      del.dispose();
    },
  };
}

const DEFAULT_EXCLUDES = new Set(["node_modules", ".git"]);

async function findFiles(include, exclude, maxResults, token) {
  const results = [];
  const limit = typeof maxResults === "number" ? maxResults : Infinity;
  const roots = include instanceof RelativePattern ? [include.baseUri.fsPath] : state.workspaceFolders.map((f) => f.uri.fsPath);
  const includeGlob = include instanceof RelativePattern ? include.pattern : String(include);
  const includeRe = globToRegExp(includeGlob);
  const excludeRe = exclude ? globToRegExp(exclude instanceof RelativePattern ? exclude.pattern : String(exclude)) : null;
  const useDefaultExcludes = exclude === undefined;
  for (const root of roots) {
    const stack = [""];
    while (stack.length && results.length < limit) {
      if (token && token.isCancellationRequested) return results;
      const rel = stack.pop();
      let entries;
      try {
        entries = await fs.promises.readdir(path.join(root, rel), { withFileTypes: true });
      } catch (_) {
        continue;
      }
      for (const entry of entries) {
        const childRel = rel ? rel + "/" + entry.name : entry.name;
        if (entry.isDirectory()) {
          if (useDefaultExcludes && DEFAULT_EXCLUDES.has(entry.name)) continue;
          if (excludeRe && excludeRe.test(childRel)) continue;
          stack.push(childRel);
        } else if (includeRe.test(childRel) && !(excludeRe && excludeRe.test(childRel))) {
          results.push(Uri.file(path.join(root, childRel)));
          if (results.length >= limit) break;
        }
      }
    }
  }
  return results;
}

function fsError(err, uri) {
  const map = { ENOENT: "FileNotFound", EEXIST: "FileExists", ENOTDIR: "FileNotADirectory", EISDIR: "FileIsADirectory", EACCES: "NoPermissions", EPERM: "NoPermissions" };
  const e = new FileSystemError(uri, map[err && err.code] || "Unknown");
  e.message = (err && err.message) || e.message;
  return e;
}

function statType(st) {
  if (st.isSymbolicLink()) return FileType.SymbolicLink | (st.isDirectory() ? FileType.Directory : FileType.File);
  if (st.isDirectory()) return FileType.Directory;
  if (st.isFile()) return FileType.File;
  return FileType.Unknown;
}

const workspaceFs = {
  async stat(uri) {
    const u = asUri(uri);
    try {
      const st = await fs.promises.stat(u.fsPath);
      return { type: statType(st), ctime: st.ctimeMs, mtime: st.mtimeMs, size: st.size };
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async readDirectory(uri) {
    const u = asUri(uri);
    try {
      const entries = await fs.promises.readdir(u.fsPath, { withFileTypes: true });
      return entries.map((e) => [e.name, e.isDirectory() ? FileType.Directory : e.isFile() ? FileType.File : e.isSymbolicLink() ? FileType.SymbolicLink : FileType.Unknown]);
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async createDirectory(uri) {
    const u = asUri(uri);
    try {
      await fs.promises.mkdir(u.fsPath, { recursive: true });
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async readFile(uri) {
    const u = asUri(uri);
    try {
      const buf = await fs.promises.readFile(u.fsPath);
      return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async writeFile(uri, content) {
    const u = asUri(uri);
    try {
      await fs.promises.mkdir(path.dirname(u.fsPath), { recursive: true });
      await fs.promises.writeFile(u.fsPath, Buffer.from(content));
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async delete(uri, options) {
    const u = asUri(uri);
    try {
      await fs.promises.rm(u.fsPath, { recursive: !!(options && options.recursive), force: false });
    } catch (err) {
      throw fsError(err, u);
    }
  },
  async rename(source, target, options) {
    const s = asUri(source);
    const t = asUri(target);
    try {
      if (!(options && options.overwrite) && fs.existsSync(t.fsPath)) throw Object.assign(new Error("target exists"), { code: "EEXIST" });
      await fs.promises.rename(s.fsPath, t.fsPath);
    } catch (err) {
      throw fsError(err, t);
    }
  },
  async copy(source, target, options) {
    const s = asUri(source);
    const t = asUri(target);
    try {
      if (!(options && options.overwrite) && fs.existsSync(t.fsPath)) throw Object.assign(new Error("target exists"), { code: "EEXIST" });
      await fs.promises.cp(s.fsPath, t.fsPath, { recursive: true, force: true });
    } catch (err) {
      throw fsError(err, t);
    }
  },
  isWritableFileSystem(scheme) {
    return scheme === "file" ? true : undefined;
  },
};

// ---------------------------------------------------------------------------
// Languages known to the host: contributed ids plus the common ones, for
// getLanguages() and for guessing the id of a file read from disk.

const BUILTIN_EXTENSIONS = {
  ".js": "javascript", ".cjs": "javascript", ".mjs": "javascript", ".jsx": "javascriptreact", ".ts": "typescript", ".mts": "typescript",
  ".cts": "typescript", ".tsx": "typescriptreact", ".json": "json", ".jsonc": "jsonc", ".md": "markdown", ".py": "python", ".lua": "lua",
  ".rs": "rust", ".go": "go", ".html": "html", ".htm": "html", ".css": "css", ".scss": "scss", ".less": "less", ".yaml": "yaml", ".yml": "yaml",
  ".toml": "toml", ".sh": "shellscript", ".ps1": "powershell", ".c": "c", ".h": "c", ".cpp": "cpp", ".hpp": "cpp", ".java": "java",
  ".rb": "ruby", ".php": "php", ".vue": "vue", ".svelte": "svelte", ".xml": "xml", ".sql": "sql", ".graphql": "graphql", ".txt": "plaintext",
};

function languageForPath(fsPath) {
  const base = path.basename(fsPath);
  const ext = path.extname(base).toLowerCase();
  const contributed = ((host.extension && host.extension.pkg && host.extension.pkg.contributes) || {}).languages || [];
  for (const lang of contributed) {
    if (Array.isArray(lang.filenames) && lang.filenames.includes(base)) return lang.id;
    if (Array.isArray(lang.extensions) && lang.extensions.some((e) => e.toLowerCase() === ext)) return lang.id;
  }
  return BUILTIN_EXTENSIONS[ext] || "plaintext";
}

function knownLanguages() {
  const ids = new Set(Object.values(BUILTIN_EXTENSIONS));
  const contributed = ((host.extension && host.extension.pkg && host.extension.pkg.contributes) || {}).languages || [];
  for (const lang of contributed) if (lang && lang.id) ids.add(lang.id);
  return Array.from(ids);
}

// ---------------------------------------------------------------------------
// Workspace folders.

function setWorkspaceFolders(folders) {
  state.workspaceFolders = (folders || []).map((f, i) => {
    const uri = typeof f.uri === "string" ? Uri.parse(f.uri) : f.uri;
    return { uri, name: f.name || path.basename(uri.fsPath) || uri.toString(), index: i };
  });
}

function getWorkspaceFolder(uri) {
  const u = asUri(uri);
  const target = slashes(u.fsPath);
  let best = null;
  for (const f of state.workspaceFolders) {
    const base = slashes(f.uri.fsPath).replace(/\/$/, "");
    if (relativeTo(base, target) !== null && (!best || base.length > slashes(best.uri.fsPath).length)) best = f;
  }
  return best || undefined;
}

function asRelativePath(pathOrUri, includeWorkspaceFolder) {
  const fsPath = pathOrUri instanceof Uri ? pathOrUri.fsPath : String(pathOrUri);
  const folder = getWorkspaceFolder(pathOrUri instanceof Uri ? pathOrUri : Uri.file(fsPath));
  if (!folder) return slashes(fsPath);
  const rel = relativeTo(slashes(folder.uri.fsPath).replace(/\/$/, ""), slashes(fsPath));
  const many = state.workspaceFolders.length > 1;
  if (includeWorkspaceFolder === undefined ? many : includeWorkspaceFolder) return folder.name + "/" + rel;
  return rel;
}

// ---------------------------------------------------------------------------
// Editors: nvs.ide has no editor objects, so the only TextEditor an extension can
// get is the one showTextDocument returns, and its edit() goes through applyEdit.

function makeEditor(document) {
  return {
    document,
    selection: new Selection(0, 0, 0, 0),
    selections: [new Selection(0, 0, 0, 0)],
    visibleRanges: [],
    options: { tabSize: 4, insertSpaces: true },
    viewColumn: ViewColumn.One,
    async edit(callback) {
      const we = new WorkspaceEdit();
      const builder = {
        replace: (range, text) => we.replace(document.uri, range instanceof Position ? new Range(range, range) : range, text),
        insert: (position, text) => we.insert(document.uri, position, text),
        delete: (range) => we.delete(document.uri, range),
        setEndOfLine: () => unsupported("TextEditorEdit.setEndOfLine"),
      };
      callback(builder);
      return applyEdit(we);
    },
    async insertSnippet() {
      unsupported("TextEditor.insertSnippet");
      return false;
    },
    setDecorations() {
      unsupported("TextEditor.setDecorations");
    },
    revealRange() {},
    show() {},
    hide() {},
  };
}

function applyEdit(edit) {
  return clientRequest("workspace/applyEdit", { edit: toLspWorkspaceEdit(edit) }).then(
    (r) => !!(r && r.applied),
    (err) => {
      log("warn", "applyEdit failed: " + describe(err));
      return false;
    }
  );
}

// ---------------------------------------------------------------------------
// Namespaces.

const events = {
  openDoc: new EventEmitter(),
  changeDoc: new EventEmitter(),
  closeDoc: new EventEmitter(),
  saveDoc: new EventEmitter(),
  willSaveDoc: new EventEmitter(),
  foldersChanged: new EventEmitter(),
  trustGranted: new EventEmitter(),
  never: new EventEmitter(),
};

const window = namespace("window", {
  get activeTextEditor() {
    return undefined;
  },
  get visibleTextEditors() {
    return [];
  },
  get activeTerminal() {
    return undefined;
  },
  get terminals() {
    return [];
  },
  get activeNotebookEditor() {
    return undefined;
  },
  get visibleNotebookEditors() {
    return [];
  },
  state: { focused: true, active: true },
  activeColorTheme: { kind: ColorThemeKind.Dark },
  tabGroups: {
    all: [],
    activeTabGroup: { isActive: true, viewColumn: ViewColumn.One, activeTab: undefined, tabs: [] },
    onDidChangeTabGroups: events.never.event,
    onDidChangeTabs: events.never.event,
    close: async () => false,
  },
  onDidChangeActiveTextEditor: events.never.event,
  onDidChangeVisibleTextEditors: events.never.event,
  onDidChangeTextEditorSelection: events.never.event,
  onDidChangeTextEditorVisibleRanges: events.never.event,
  onDidChangeTextEditorOptions: events.never.event,
  onDidChangeTextEditorViewColumn: events.never.event,
  onDidChangeWindowState: events.never.event,
  onDidOpenTerminal: events.never.event,
  onDidCloseTerminal: events.never.event,
  onDidChangeActiveTerminal: events.never.event,
  onDidChangeTerminalState: events.never.event,
  onDidChangeTerminalShellIntegration: events.never.event,
  onDidStartTerminalShellExecution: events.never.event,
  onDidEndTerminalShellExecution: events.never.event,
  onDidChangeActiveColorTheme: events.never.event,
  onDidChangeActiveNotebookEditor: events.never.event,
  onDidChangeVisibleNotebookEditors: events.never.event,
  onDidChangeNotebookEditorSelection: events.never.event,
  onDidChangeNotebookEditorVisibleRanges: events.never.event,
  showInformationMessage: (message, ...rest) => showMessage(MessageType.Info, message, rest),
  showWarningMessage: (message, ...rest) => showMessage(MessageType.Warning, message, rest),
  showErrorMessage: (message, ...rest) => showMessage(MessageType.Error, message, rest),
  createOutputChannel,
  createStatusBarItem,
  withProgress,
  setStatusBarMessage(text, hideAfterOrPromise) {
    log("info", "status bar message: " + text);
    logMessage(MessageType.Log, "status bar message: " + text);
    return new Disposable(() => {});
  },
  async showTextDocument(documentOrUri, columnOrOptions, preserveFocus) {
    const uri = documentOrUri instanceof Uri ? documentOrUri : documentOrUri.uri;
    const options = columnOrOptions && typeof columnOrOptions === "object" ? columnOrOptions : { preserveFocus };
    await showDocument(uri, options);
    const doc = documentOrUri instanceof Uri ? await workspace.openTextDocument(uri) : documentOrUri;
    return makeEditor(doc);
  },
  showQuickPick(itemsOrPromise, options) {
    // A quick pick maps onto showMessageRequest: the client (vim.ui.select) offers
    // the labels and the chosen item comes back.
    return Promise.resolve(itemsOrPromise).then((items) => {
      const list = (items || []).filter((i) => i !== undefined && !(i && i.kind === QuickPickItemKind.Separator));
      if (!list.length) return undefined;
      const labels = list.map((i) => (typeof i === "string" ? i : String(i.label)));
      const message = (options && (options.title || options.placeHolder)) || "Pick one";
      return clientRequest("window/showMessageRequest", { type: MessageType.Info, message, actions: labels.map((title) => ({ title })) }).then(
        (res) => {
          if (!res || !res.title) return undefined;
          const idx = labels.indexOf(res.title);
          const chosen = idx >= 0 ? list[idx] : undefined;
          return options && options.canPickMany ? (chosen === undefined ? undefined : [chosen]) : chosen;
        },
        () => undefined
      );
    });
  },
  showInputBox() {
    unsupported("window.showInputBox");
    return Promise.resolve(undefined);
  },
  showOpenDialog() {
    unsupported("window.showOpenDialog");
    return Promise.resolve(undefined);
  },
  showSaveDialog() {
    unsupported("window.showSaveDialog");
    return Promise.resolve(undefined);
  },
  showWorkspaceFolderPick() {
    return Promise.resolve(state.workspaceFolders[0]);
  },
  createTextEditorDecorationType(options) {
    unsupported("window.createTextEditorDecorationType");
    return { key: "decoration-" + ++statusSeq, dispose() {} };
  },
  registerUriHandler() {
    unsupported("window.registerUriHandler");
    return new Disposable(() => {});
  },
  registerFileDecorationProvider() {
    unsupported("window.registerFileDecorationProvider");
    return new Disposable(() => {});
  },
  registerTerminalLinkProvider() {
    unsupported("window.registerTerminalLinkProvider");
    return new Disposable(() => {});
  },
  registerTerminalProfileProvider() {
    unsupported("window.registerTerminalProfileProvider");
    return new Disposable(() => {});
  },
});

const workspace = namespace("workspace", {
  get workspaceFolders() {
    return state.workspaceFolders.length ? state.workspaceFolders.slice() : undefined;
  },
  get rootPath() {
    return state.workspaceFolders.length ? state.workspaceFolders[0].uri.fsPath : undefined;
  },
  get name() {
    return state.workspaceFolders.length ? state.workspaceFolders[0].name : undefined;
  },
  get workspaceFile() {
    return undefined;
  },
  get isTrusted() {
    return true;
  },
  get textDocuments() {
    return host.documents ? host.documents.all() : [];
  },
  get notebookDocuments() {
    return [];
  },
  fs: workspaceFs,
  onDidGrantWorkspaceTrust: events.trustGranted.event,
  onDidChangeWorkspaceFolders: events.foldersChanged.event,
  onDidOpenTextDocument: events.openDoc.event,
  onDidChangeTextDocument: events.changeDoc.event,
  onDidCloseTextDocument: events.closeDoc.event,
  onDidSaveTextDocument: events.saveDoc.event,
  onWillSaveTextDocument: events.willSaveDoc.event,
  onDidChangeConfiguration: configEmitter.event,
  onDidCreateFiles: events.never.event,
  onDidDeleteFiles: events.never.event,
  onDidRenameFiles: events.never.event,
  onWillCreateFiles: events.never.event,
  onWillDeleteFiles: events.never.event,
  onWillRenameFiles: events.never.event,
  onDidOpenNotebookDocument: events.never.event,
  onDidCloseNotebookDocument: events.never.event,
  onDidChangeNotebookDocument: events.never.event,
  onDidSaveNotebookDocument: events.never.event,
  onWillSaveNotebookDocument: events.never.event,
  getConfiguration: (section, scope) => makeConfiguration(section, scope),
  getWorkspaceFolder,
  asRelativePath,
  updateWorkspaceFolders() {
    unsupported("workspace.updateWorkspaceFolders");
    return false;
  },
  createFileSystemWatcher,
  findFiles,
  applyEdit,
  async openTextDocument(uriOrFileNameOrOptions) {
    if (uriOrFileNameOrOptions === undefined || (uriOrFileNameOrOptions && typeof uriOrFileNameOrOptions === "object" && !(uriOrFileNameOrOptions instanceof Uri))) {
      const o = uriOrFileNameOrOptions || {};
      return host.documents.openUntitled(o.content, o.language);
    }
    const uri = typeof uriOrFileNameOrOptions === "string" ? Uri.file(uriOrFileNameOrOptions) : asUri(uriOrFileNameOrOptions);
    const existing = host.documents.get(uri.toString());
    if (existing) return existing;
    if (uri.scheme === "untitled") return host.documents.openUntitled("", undefined);
    if (uri.scheme !== "file") throw new Error("cannot open " + uri.toString() + ": only file documents can be read");
    const doc = host.documents.openExternal(uri);
    if (!doc) throw new Error("cannot open " + uri.toString());
    return doc;
  },
  async saveAll() {
    unsupported("workspace.saveAll");
    return false;
  },
  async save(uri) {
    unsupported("workspace.save");
    return undefined;
  },
  async saveAs() {
    unsupported("workspace.saveAs");
    return undefined;
  },
  registerTextDocumentContentProvider(scheme) {
    unsupported("workspace.registerTextDocumentContentProvider(" + scheme + ")");
    return new Disposable(() => {});
  },
  registerTaskProvider() {
    unsupported("workspace.registerTaskProvider");
    return new Disposable(() => {});
  },
  registerFileSystemProvider(scheme) {
    unsupported("workspace.registerFileSystemProvider(" + scheme + ")");
    return new Disposable(() => {});
  },
  registerNotebookSerializer() {
    unsupported("workspace.registerNotebookSerializer");
    return new Disposable(() => {});
  },
  async openNotebookDocument() {
    unsupported("workspace.openNotebookDocument");
    return undefined;
  },
  async decode(content, options) {
    return Buffer.from(content).toString((options && options.encoding) || "utf8");
  },
  async encode(content, options) {
    const buf = Buffer.from(String(content), (options && options.encoding) || "utf8");
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  },
});

const languages = namespace("languages", {
  createDiagnosticCollection: (name) => new DiagnosticCollection(name || "default"),
  getDiagnostics(uri) {
    if (uri) {
      const out = [];
      for (const c of collections) {
        const e = c._map.get(uri.toString());
        if (e) out.push(...e.diagnostics);
      }
      return out;
    }
    const byUri = new Map();
    for (const c of collections) {
      for (const e of c._map.values()) {
        const key = e.uri.toString();
        if (!byUri.has(key)) byUri.set(key, [e.uri, []]);
        byUri.get(key)[1].push(...e.diagnostics);
      }
    }
    return Array.from(byUri.values());
  },
  onDidChangeDiagnostics: diagnosticsEmitter.event,
  getLanguages: () => Promise.resolve(knownLanguages()),
  async setTextDocumentLanguage(document, languageId) {
    unsupported("languages.setTextDocumentLanguage");
    return document;
  },
  match: (selector, document) => score(selector, document),
  setLanguageConfiguration: () => new Disposable(() => {}),
  createLanguageStatusItem(id, selector) {
    return { id, selector, name: undefined, text: "", detail: undefined, busy: false, severity: LanguageStatusSeverity.Information, command: undefined, accessibilityInformation: undefined, dispose() {} };
  },
  registerCompletionItemProvider: (selector, provider, ...triggerCharacters) => registerProvider("completion", selector, provider, { triggerCharacters }),
  registerHoverProvider: (selector, provider) => registerProvider("hover", selector, provider),
  registerDefinitionProvider: (selector, provider) => registerProvider("definition", selector, provider),
  registerDeclarationProvider: (selector, provider) => registerProvider("declaration", selector, provider),
  registerImplementationProvider: (selector, provider) => registerProvider("implementation", selector, provider),
  registerTypeDefinitionProvider: (selector, provider) => registerProvider("typeDefinition", selector, provider),
  registerReferenceProvider: (selector, provider) => registerProvider("references", selector, provider),
  registerDocumentHighlightProvider: (selector, provider) => registerProvider("documentHighlight", selector, provider),
  registerDocumentSymbolProvider: (selector, provider, metadata) => registerProvider("documentSymbol", selector, provider, metadata),
  registerWorkspaceSymbolProvider: (provider) => registerProvider("workspaceSymbol", "*", provider),
  registerCodeActionsProvider: (selector, provider, metadata) => registerProvider("codeAction", selector, provider, metadata),
  registerCodeLensProvider: (selector, provider) => registerProvider("codeLens", selector, provider),
  registerDocumentLinkProvider: (selector, provider) => registerProvider("documentLink", selector, provider),
  registerFoldingRangeProvider: (selector, provider) => registerProvider("foldingRange", selector, provider),
  registerRenameProvider: (selector, provider) => registerProvider("rename", selector, provider),
  registerSignatureHelpProvider(selector, provider, ...rest) {
    const meta = rest.length === 1 && rest[0] && typeof rest[0] === "object" ? rest[0] : { triggerCharacters: rest, retriggerCharacters: [] };
    return registerProvider("signatureHelp", selector, provider, meta);
  },
  registerDocumentFormattingEditProvider: (selector, provider) => registerProvider("formatting", selector, provider),
  registerDocumentRangeFormattingEditProvider: (selector, provider) => registerProvider("rangeFormatting", selector, provider),
  registerOnTypeFormattingEditProvider: (selector, provider) => registerUnrouted("registerOnTypeFormattingEditProvider", selector, provider),
  registerInlayHintsProvider: (selector, provider) => registerUnrouted("registerInlayHintsProvider", selector, provider),
  registerColorProvider: (selector, provider) => registerUnrouted("registerColorProvider", selector, provider),
  registerSelectionRangeProvider: (selector, provider) => registerUnrouted("registerSelectionRangeProvider", selector, provider),
  registerCallHierarchyProvider: (selector, provider) => registerUnrouted("registerCallHierarchyProvider", selector, provider),
  registerTypeHierarchyProvider: (selector, provider) => registerUnrouted("registerTypeHierarchyProvider", selector, provider),
  registerLinkedEditingRangeProvider: (selector, provider) => registerUnrouted("registerLinkedEditingRangeProvider", selector, provider),
  registerDocumentSemanticTokensProvider: (selector, provider) => registerUnrouted("registerDocumentSemanticTokensProvider", selector, provider),
  registerDocumentRangeSemanticTokensProvider: (selector, provider) => registerUnrouted("registerDocumentRangeSemanticTokensProvider", selector, provider),
  registerInlineCompletionItemProvider: (selector, provider) => registerUnrouted("registerInlineCompletionItemProvider", selector, provider),
  registerEvaluatableExpressionProvider: (selector, provider) => registerUnrouted("registerEvaluatableExpressionProvider", selector, provider),
  registerInlineValuesProvider: (selector, provider) => registerUnrouted("registerInlineValuesProvider", selector, provider),
  registerDocumentDropEditProvider: (selector, provider) => registerUnrouted("registerDocumentDropEditProvider", selector, provider),
  registerDocumentPasteEditProvider: (selector, provider) => registerUnrouted("registerDocumentPasteEditProvider", selector, provider),
  registerDocumentRangesFormattingEditProvider: (selector, provider) => registerUnrouted("registerDocumentRangesFormattingEditProvider", selector, provider),
});

const BUILTIN_COMMANDS = {
  setContext: (key, value) => {
    contexts.set(key, value);
  },
  "vscode.open": (uri, options) => showDocument(uri, options && typeof options === "object" ? options : undefined),
  "vscode.openWith": (uri) => showDocument(uri),
  "editor.action.formatDocument": () => undefined,
  "editor.action.formatSelection": () => undefined,
  "workbench.action.files.save": () => undefined,
  "workbench.action.files.saveAll": () => undefined,
  "workbench.action.focusActiveEditorGroup": () => undefined,
};

const commands = namespace("commands", {
  registerCommand(id, callback, thisArg) {
    if (commandsRegistry.has(id)) log("warn", "command " + id + " registered twice; the newer one wins");
    commandsRegistry.set(id, { fn: callback, thisArg });
    if (hooks.onCommandChange) hooks.onCommandChange(id, true);
    return new Disposable(() => {
      if (commandsRegistry.get(id) && commandsRegistry.get(id).fn === callback) {
        commandsRegistry.delete(id);
        if (hooks.onCommandChange) hooks.onCommandChange(id, false);
      }
    });
  },
  registerTextEditorCommand(id, callback, thisArg) {
    // The callback wants a TextEditor; without one it is called with the arguments
    // it can get, and a log line says why it may not do what the author expects.
    return commands.registerCommand(
      id,
      (...args) => {
        unsupported("commands.registerTextEditorCommand(" + id + ") called without an editor");
        return callback.call(thisArg, undefined, undefined, ...args);
      },
      thisArg
    );
  },
  async executeCommand(id, ...args) {
    const own = commandsRegistry.get(id);
    if (own) return own.fn.apply(own.thisArg, args);
    if (Object.prototype.hasOwnProperty.call(BUILTIN_COMMANDS, id)) return BUILTIN_COMMANDS[id](...args);
    unsupported("commands.executeCommand(" + id + ")");
    return undefined;
  },
  async getCommands(filterInternal) {
    return [...commandsRegistry.keys(), ...Object.keys(BUILTIN_COMMANDS)].filter((c) => !filterInternal || !c.startsWith("_"));
  },
});

const env = namespace("env", {
  appName: "nvs.ide",
  appRoot: process.env.NVS_APP_ROOT || path.dirname(path.dirname(__dirname)),
  appHost: "desktop",
  uriScheme: "nvs-ide",
  language: (process.env.LANG || "en").split(/[._:]/)[0].replace("_", "-") || "en",
  machineId: crypto.createHash("sha256").update(os.hostname() + os.userInfo().username).digest("hex").slice(0, 32),
  sessionId: crypto.randomBytes(16).toString("hex"),
  uiKind: UIKind.Desktop,
  shell: process.env.SHELL || process.env.ComSpec || "",
  remoteName: undefined,
  isNewAppInstall: false,
  isTelemetryEnabled: false,
  onDidChangeTelemetryEnabled: events.never.event,
  onDidChangeShell: events.never.event,
  logLevel: LogLevel.Info,
  onDidChangeLogLevel: events.never.event,
  clipboard: {
    readText() {
      unsupported("env.clipboard.readText");
      return Promise.resolve("");
    },
    writeText() {
      unsupported("env.clipboard.writeText");
      return Promise.resolve();
    },
  },
  openExternal: (target) => showDocument(target),
  asExternalUri: (target) => Promise.resolve(target),
  createTelemetryLogger: () => ({ logUsage() {}, logError() {}, dispose() {}, isUsageEnabled: false, isErrorsEnabled: false, onDidChangeEnableStates: events.never.event }),
});

function selfExtension() {
  const e = host.extension;
  if (!e) return undefined;
  return {
    id: e.id,
    extensionUri: Uri.file(e.root),
    extensionPath: e.root,
    isActive: true,
    packageJSON: e.pkg,
    extensionKind: ExtensionKind.Workspace,
    exports: e.exports,
    activate: () => Promise.resolve(e.exports),
  };
}

const extensions = namespace("extensions", {
  getExtension(id) {
    if (host.extension && typeof id === "string" && id.toLowerCase() === host.extension.id.toLowerCase()) return selfExtension();
    return undefined;
  },
  get all() {
    const self = selfExtension();
    return self ? [self] : [];
  },
  onDidChange: events.never.event,
});

const l10n = namespace("l10n", {
  t(...args) {
    let message;
    let params = [];
    if (typeof args[0] === "string") {
      message = args[0];
      params = args.slice(1);
      if (params.length === 1 && isPlainObject(params[0])) params = params[0];
    } else if (args[0] && typeof args[0] === "object") {
      message = args[0].message;
      params = args[0].args || [];
    } else {
      return String(args[0]);
    }
    return String(message).replace(/\{(\w+)\}/g, (m, k) => {
      const v = Array.isArray(params) ? params[Number(k)] : params[k];
      return v === undefined ? m : String(v);
    });
  },
  bundle: undefined,
  uri: undefined,
});

const debug = namespace("debug", {
  activeDebugSession: undefined,
  activeDebugConsole: { append: (v) => log("info", "debug console: " + v), appendLine: (v) => log("info", "debug console: " + v) },
  breakpoints: [],
  activeStackItem: undefined,
  onDidChangeActiveDebugSession: events.never.event,
  onDidStartDebugSession: events.never.event,
  onDidReceiveDebugSessionCustomEvent: events.never.event,
  onDidTerminateDebugSession: events.never.event,
  onDidChangeBreakpoints: events.never.event,
  onDidChangeActiveStackItem: events.never.event,
  registerDebugConfigurationProvider() {
    unsupported("debug.registerDebugConfigurationProvider");
    return new Disposable(() => {});
  },
  registerDebugAdapterDescriptorFactory() {
    unsupported("debug.registerDebugAdapterDescriptorFactory");
    return new Disposable(() => {});
  },
  registerDebugAdapterTrackerFactory() {
    unsupported("debug.registerDebugAdapterTrackerFactory");
    return new Disposable(() => {});
  },
  async startDebugging() {
    unsupported("debug.startDebugging");
    return false;
  },
  async stopDebugging() {
    unsupported("debug.stopDebugging");
  },
  addBreakpoints() {},
  removeBreakpoints() {},
  asDebugSourceUri: (source) => Uri.parse(String((source && source.path) || "debug:unknown")),
});

const tasks = namespace("tasks", {
  taskExecutions: [],
  onDidStartTask: events.never.event,
  onDidEndTask: events.never.event,
  onDidStartTaskProcess: events.never.event,
  onDidEndTaskProcess: events.never.event,
  registerTaskProvider() {
    unsupported("tasks.registerTaskProvider");
    return new Disposable(() => {});
  },
  async fetchTasks() {
    return [];
  },
  async executeTask() {
    unsupported("tasks.executeTask");
    return undefined;
  },
});

const lm = namespace("lm", {
  tools: [],
  onDidChangeChatModels: events.never.event,
  async selectChatModels() {
    return [];
  },
  registerTool() {
    unsupported("lm.registerTool");
    return new Disposable(() => {});
  },
  async invokeTool() {
    unsupported("lm.invokeTool");
    return undefined;
  },
  registerMcpServerDefinitionProvider() {
    unsupported("lm.registerMcpServerDefinitionProvider");
    return new Disposable(() => {});
  },
});

const authentication = namespace("authentication", {
  onDidChangeSessions: events.never.event,
  async getSession() {
    unsupported("authentication.getSession");
    return undefined;
  },
  async getAccounts() {
    return [];
  },
  registerAuthenticationProvider() {
    unsupported("authentication.registerAuthenticationProvider");
    return new Disposable(() => {});
  },
});

const scm = namespace("scm", { inputBox: { value: "", placeholder: "", enabled: true, visible: true } });
const comments = namespace("comments", {});
const tests = namespace("tests", { onDidChangeTestResults: events.never.event, testResults: [] });
const notebooks = namespace("notebooks", {});
const chat = namespace("chat", { onDidDisposeChatSession: events.never.event });

// ---------------------------------------------------------------------------
// The extension context.

class Memento {
  constructor(file) {
    this._file = file;
    this._data = readJsonFile(file) || {};
  }
  keys() {
    return Object.keys(this._data);
  }
  get(key, defaultValue) {
    const v = this._data[key];
    return v === undefined ? defaultValue : v;
  }
  update(key, value) {
    if (value === undefined) delete this._data[key];
    else this._data[key] = value;
    writeJsonFile(this._file, this._data);
    return Promise.resolve();
  }
  setKeysForSync() {}
}

class Secrets {
  constructor() {
    // Kept in memory only: secrets must not land in a plain JSON file.
    this._map = new Map();
    this._emitter = new EventEmitter();
    this.onDidChange = this._emitter.event;
  }
  async get(key) {
    return this._map.get(key);
  }
  async store(key, value) {
    this._map.set(key, value);
    this._emitter.fire({ key });
  }
  async delete(key) {
    this._map.delete(key);
    this._emitter.fire({ key });
  }
  async keys() {
    return Array.from(this._map.keys());
  }
}

function buildContext() {
  const e = host.extension;
  const stateDir = host.stateDir;
  const globalStorage = path.join(stateDir, "globalStorage");
  const workspaceKey = state.workspaceFolders.length
    ? crypto.createHash("sha1").update(state.workspaceFolders.map((f) => f.uri.toString()).join("|")).digest("hex").slice(0, 12)
    : "no-workspace";
  const workspaceStorage = path.join(stateDir, "workspaceStorage", workspaceKey);
  const logDir = host.logFile ? path.dirname(host.logFile) : stateDir;
  const envCollection = {
    persistent: true,
    description: undefined,
    replace() {},
    append() {},
    prepend() {},
    get() {
      return undefined;
    },
    forEach() {},
    delete() {},
    clear() {},
    getScoped() {
      return envCollection;
    },
    [Symbol.iterator]: () => [][Symbol.iterator](),
  };
  return {
    subscriptions: [],
    workspaceState: new Memento(path.join(stateDir, "workspaceState.json")),
    globalState: new Memento(path.join(stateDir, "globalState.json")),
    secrets: new Secrets(),
    extensionUri: Uri.file(e.root),
    extensionPath: e.root,
    environmentVariableCollection: envCollection,
    asAbsolutePath: (relativePath) => path.join(e.root, relativePath),
    storageUri: Uri.file(workspaceStorage),
    storagePath: workspaceStorage,
    globalStorageUri: Uri.file(globalStorage),
    globalStoragePath: globalStorage,
    logUri: Uri.file(logDir),
    logPath: logDir,
    extensionMode: ExtensionMode.Production,
    extension: selfExtension(),
    languageModelAccessInformation: { onDidChange: events.never.event, canSendRequest: () => undefined },
  };
}

// ---------------------------------------------------------------------------
// Host-facing API.

function install(opts) {
  host.log = opts.log || host.log;
  host.connection = opts.connection;
  host.documents = opts.documents || new Documents(host.log);
  host.documents.languageForPath = languageForPath;
  host.extension = opts.extension;
  host.dataDir = opts.dataDir;
  host.stateDir = path.join(opts.dataDir, "state", opts.extension.id);
  host.logFile = opts.logFile;
  host.settingsFile = opts.settingsFile;
  loadConfigurationDefaults(opts.extension.pkg);
  const persisted = readJsonFile(stateConfigFile());
  if (persisted) config.stateOverrides = normalizeSettings(persisted);
  if (opts.settingsFile) {
    const fileSettings = readJsonFile(opts.settingsFile);
    if (fileSettings) config.fileOverrides = normalizeSettings(fileSettings);
  }
  host.documents.on("open", (doc) => events.openDoc.fire(doc));
  host.documents.on("change", (e) => events.changeDoc.fire(e));
  host.documents.on("close", (doc) => events.closeDoc.fire(doc));
  host.documents.on("save", (doc) => events.saveDoc.fire(doc));
  host.documents.on("willSave", (e) => events.willSaveDoc.fire({ document: e.document, reason: e.reason, waitUntil() {} }));
  return host.documents;
}

function handleInitialize(params) {
  state.clientCapabilities = (params && params.capabilities) || {};
  state.clientInfo = params && params.clientInfo;
  let folders = [];
  if (Array.isArray(params && params.workspaceFolders)) folders = params.workspaceFolders;
  else if (params && params.rootUri) folders = [{ uri: params.rootUri }];
  else if (params && params.rootPath) folders = [{ uri: Uri.file(params.rootPath).toString() }];
  setWorkspaceFolders(folders);
  if (params && params.initializationOptions && isPlainObject(params.initializationOptions.settings)) {
    applySettingsLayer("clientSettings", params.initializationOptions.settings);
  }
}

function setInitialized() {
  state.initialized = true;
  flushDeferredNotifications();
  readyResolve();
  events.trustGranted.fire(undefined);
  return refreshFromClient();
}

function handleWorkspaceFoldersChanged(event) {
  const removed = new Set((event.removed || []).map((f) => f.uri));
  const kept = state.workspaceFolders.filter((f) => !removed.has(f.uri.toString()));
  const addedRaw = event.added || [];
  const before = state.workspaceFolders;
  setWorkspaceFolders([...kept.map((f) => ({ uri: f.uri.toString(), name: f.name })), ...addedRaw]);
  const added = state.workspaceFolders.slice(kept.length);
  events.foldersChanged.fire({ added, removed: before.filter((f) => removed.has(f.uri.toString())) });
}

function makeToken(ctx) {
  const cts = new CancellationTokenSource();
  if (ctx) ctx.onCancel(() => cts.cancel());
  return cts;
}

function disposeAll(context) {
  const list = context ? context.subscriptions.splice(0) : [];
  for (const d of list) {
    try {
      if (d && typeof d.dispose === "function") d.dispose();
    } catch (err) {
      log("warn", "dispose failed: " + describe(err));
    }
  }
}

const _nvs = {
  install,
  unsupported,
  state,
  providers,
  providersFor,
  commands: commandsRegistry,
  hooks,
  handleInitialize,
  setInitialized,
  handleWorkspaceFoldersChanged,
  applyClientSettings: (settings) => applySettingsLayer("clientSettings", settings),
  refreshFromClient,
  config,
  convert,
  score,
  buildContext,
  makeToken,
  disposeAll,
  showMessage,
  clientRequest,
  clientNotify,
  cancelProgress,
  gatedRequests: () => gatedRequests,
  MessageType,
  matchGlob,
  globToRegExp,
};

const version = "1.101.0";

module.exports = {
  version,
  _nvs,
  window, workspace, languages, commands, env, extensions, l10n, debug, tasks, lm, authentication, scm, comments, tests, notebooks, chat,
  Uri, Position, Range, Selection, Location, TextEdit, SnippetTextEdit, WorkspaceEdit, Diagnostic, DiagnosticRelatedInformation,
  CompletionItem, CompletionList, SnippetString, MarkdownString, Hover, SymbolInformation, DocumentSymbol, CodeAction, CodeActionKind,
  Command, Disposable, EventEmitter, CancellationTokenSource, CancellationError, RelativePattern, ThemeColor, ThemeIcon, TextDocument,
  SignatureHelp, SignatureInformation, ParameterInformation, FileSystemError, TreeItem, CodeLens, DocumentLink, DocumentHighlight,
  FoldingRange, SemanticTokensLegend, SemanticTokensBuilder, SemanticTokens, SemanticTokensEdit, SemanticTokensEdits, TelemetryTrustedValue,
  InlayHint, InlayHintLabelPart, SelectionRange, Color, ColorInformation, ColorPresentation, CallHierarchyItem, CallHierarchyIncomingCall,
  CallHierarchyOutgoingCall, TypeHierarchyItem, InlineCompletionItem, InlineCompletionList, EvaluatableExpression, InlineValueText,
  InlineValueVariableLookup, InlineValueEvaluatableExpression, LinkedEditingRanges, DocumentDropEdit, DocumentPasteEdit,
  DocumentDropOrPasteEditKind, DocumentPasteEditKind, DataTransfer, DataTransferItem, FileDecoration, TerminalLink, TerminalProfile,
  TerminalQuickFixOpener, TerminalQuickFixTerminalCommand, Task, TaskGroup, ProcessExecution, ShellExecution, CustomExecution,
  ShellExecutionOptions, Breakpoint, SourceBreakpoint, FunctionBreakpoint, DebugAdapterExecutable, DebugAdapterServer,
  DebugAdapterNamedPipeServer, DebugAdapterInlineImplementation, DebugThread, DebugStackFrame, TestTag, TestMessage, TestRunRequest,
  TestCoverageCount, FileCoverage, StatementCoverage, BranchCoverage, DeclarationCoverage, NotebookRange, NotebookCellData, NotebookData,
  NotebookCellOutput, NotebookCellOutputItem, NotebookEdit, NotebookRendererScript, TabInputText, TabInputTextDiff, TabInputCustom,
  TabInputWebview, TabInputNotebook, TabInputNotebookDiff, TabInputTerminal, QuickInputButtons, ChatRequestTurn, ChatResponseTurn,
  ChatResponseMarkdownPart, ChatResponseFileTreePart, ChatResponseAnchorPart, ChatResponseProgressPart, ChatResponseReferencePart,
  ChatResponseCommandButtonPart, LanguageModelChatMessage, LanguageModelTextPart, LanguageModelToolCallPart, LanguageModelToolResultPart,
  LanguageModelToolResult, LanguageModelPromptTsxPart, LanguageModelError, McpStdioServerDefinition, McpHttpServerDefinition, PortAttributes,
  DiagnosticSeverity, DiagnosticTag, CompletionItemKind, CompletionItemTag, CompletionTriggerKind, SymbolKind, SymbolTag, StatusBarAlignment,
  ProgressLocation, ConfigurationTarget, EndOfLine, ExtensionMode, ExtensionKind, LanguageStatusSeverity, UIKind, FileType, FilePermission,
  FileChangeType, TextDocumentSaveReason, TextDocumentChangeReason, CodeActionTriggerKind, SignatureHelpTriggerKind, DocumentHighlightKind,
  FoldingRangeKind, InlayHintKind, ViewColumn, TreeItemCollapsibleState, TreeItemCheckboxState, QuickPickItemKind, LogLevel, ColorThemeKind,
  TextEditorRevealType, TextEditorSelectionChangeKind, TextEditorLineNumbersStyle, TextEditorCursorStyle, OverviewRulerLane,
  DecorationRangeBehavior, IndentAction, EnvironmentVariableMutatorType, TaskScope, TaskRevealKind, TaskPanelKind, ShellQuoting,
  TerminalLocation, TerminalExitReason, TerminalShellExecutionCommandLineConfidence, DebugConsoleMode, DebugConfigurationProviderTriggerKind,
  CommentMode, CommentThreadCollapsibleState, CommentThreadState, NotebookCellKind, NotebookCellStatusBarAlignment, NotebookControllerAffinity,
  NotebookEditorRevealType, InlineCompletionTriggerKind, SourceControlInputBoxValidationType, TestRunProfileKind, LanguageModelChatMessageRole,
  LanguageModelChatToolMode, ChatResultFeedbackKind, ChatLocation, ExternalUriOpenerPriority, PortAutoForwardAction, TerminalOutputAnchor,
  TerminalQuickFixType, TabInputTerminalKind,
};

// Unknown top-level members (an enum this file lacks, a class added in a newer VS
// Code) come back as phantoms through the prototype, which leaves the literal
// export list above intact for Node's lexer.
Object.setPrototypeOf(
  module.exports,
  new Proxy(Object.create(null), {
    get(_t, key) {
      if (typeof key !== "string" || NAMESPACE_SKIP.has(key)) return undefined;
      unsupported(key);
      return phantom(key);
    },
  })
);
