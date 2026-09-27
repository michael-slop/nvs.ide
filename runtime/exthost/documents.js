"use strict";
// The TextDocument store: one vscode.TextDocument per open buffer, kept in sync from
// textDocument/didOpen, didChange (incremental or full), didClose and didSave.
//
// Positions are UTF-16 code units, which is what both VS Code and JavaScript string
// indexes use, so the host answers Neovim with positionEncoding "utf-16" and never
// converts offsets.

const fs = require("fs");

// vscode.js requires this file at load time; requiring it back at the top would give
// a half-built module, so the type classes are looked up on first use.
let types = null;
function T() {
  if (!types) types = require("./vscode.js");
  return types;
}

const WORD_RE = /(-?\d*\.\d\w*)|([^`~!@#$%^&*()\-=+[{\]}\\|;:'",.<>/?\s]+)/g;

class TextDocument {
  constructor(uri, languageId, version, text, options) {
    const { Uri } = T();
    this._uri = uri instanceof Uri ? uri : Uri.parse(String(uri));
    this._languageId = languageId || "plaintext";
    this._version = version || 0;
    this._text = text || "";
    this._lineStarts = null;
    this._isClosed = false;
    this._isDirty = false;
    this._untitled = this._uri.scheme === "untitled";
    // A document opened from disk by workspace.openTextDocument is not synced by the
    // client; the store remembers which ones those are.
    this._external = !!(options && options.external);
  }

  get uri() {
    return this._uri;
  }
  get fileName() {
    return this._uri.fsPath;
  }
  get isUntitled() {
    return this._untitled;
  }
  get languageId() {
    return this._languageId;
  }
  get version() {
    return this._version;
  }
  get isDirty() {
    return this._isDirty;
  }
  get isClosed() {
    return this._isClosed;
  }
  get eol() {
    const { EndOfLine } = T();
    const i = this._text.indexOf("\n");
    return i > 0 && this._text[i - 1] === "\r" ? EndOfLine.CRLF : EndOfLine.LF;
  }
  get lineCount() {
    return this._starts().length;
  }
  get encoding() {
    return "utf8";
  }

  save() {
    // There is no LSP message that asks the client to write a buffer.
    T()._nvs.unsupported("TextDocument.save");
    return Promise.resolve(false);
  }

  // Line start offsets; the last entry is the start of the line after the final
  // line break, which is the empty last line when the text ends with a newline.
  _starts() {
    if (this._lineStarts) return this._lineStarts;
    const starts = [0];
    const t = this._text;
    for (let i = 0; i < t.length; i++) {
      const c = t.charCodeAt(i);
      if (c === 13) {
        if (i + 1 < t.length && t.charCodeAt(i + 1) === 10) i++;
        starts.push(i + 1);
      } else if (c === 10) {
        starts.push(i + 1);
      }
    }
    this._lineStarts = starts;
    return starts;
  }

  _lineEnd(line) {
    const starts = this._starts();
    if (line + 1 < starts.length) {
      let end = starts[line + 1];
      if (this._text.charCodeAt(end - 1) === 10) end--;
      if (end > starts[line] && this._text.charCodeAt(end - 1) === 13) end--;
      return end;
    }
    return this._text.length;
  }

  getText(range) {
    if (!range) return this._text;
    const r = this.validateRange(range);
    return this._text.slice(this.offsetAt(r.start), this.offsetAt(r.end));
  }

  offsetAt(position) {
    const starts = this._starts();
    const { Position } = T();
    if (!(position instanceof Position)) position = new Position(position.line, position.character);
    if (position.line < 0) return 0;
    if (position.line >= starts.length) return this._text.length;
    const start = starts[position.line];
    const end = this._lineEnd(position.line);
    return Math.min(start + Math.max(0, position.character), end);
  }

  positionAt(offset) {
    const { Position } = T();
    const starts = this._starts();
    offset = Math.max(0, Math.min(offset | 0, this._text.length));
    let lo = 0;
    let hi = starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) lo = mid;
      else hi = mid - 1;
    }
    const lineEnd = this._lineEnd(lo);
    return new Position(lo, Math.min(offset, lineEnd) - starts[lo]);
  }

  lineAt(lineOrPosition) {
    const { Position, Range } = T();
    let line = typeof lineOrPosition === "number" ? lineOrPosition : lineOrPosition.line;
    const count = this.lineCount;
    if (typeof line !== "number" || line < 0 || line >= count) {
      throw new Error("Illegal value for `line`");
    }
    const starts = this._starts();
    const start = starts[line];
    const end = this._lineEnd(line);
    const text = this._text.slice(start, end);
    const nonWs = text.search(/\S/);
    const last = line === count - 1;
    const range = new Range(new Position(line, 0), new Position(line, text.length));
    const rangeIncludingLineBreak = last ? range : new Range(new Position(line, 0), new Position(line + 1, 0));
    return {
      lineNumber: line,
      text,
      range,
      rangeIncludingLineBreak,
      firstNonWhitespaceCharacterIndex: nonWs < 0 ? text.length : nonWs,
      isEmptyOrWhitespace: nonWs < 0,
    };
  }

  validatePosition(position) {
    const { Position } = T();
    const count = this.lineCount;
    let line = Math.max(0, Math.min(position.line | 0, count - 1));
    const len = this._lineEnd(line) - this._starts()[line];
    let character = Math.max(0, Math.min(position.character | 0, len));
    if (line === position.line && character === position.character && position instanceof Position) return position;
    return new Position(line, character);
  }

  validateRange(range) {
    const { Range } = T();
    const start = this.validatePosition(range.start);
    const end = this.validatePosition(range.end);
    if (start === range.start && end === range.end && range instanceof Range) return range;
    return new Range(start, end);
  }

  getWordRangeAtPosition(position, regex) {
    const { Range, Position } = T();
    const pos = this.validatePosition(position);
    const text = this.lineAt(pos.line).text;
    let re = regex || WORD_RE;
    re = new RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text))) {
      if (m[0].length === 0) {
        re.lastIndex++;
        continue;
      }
      const s = m.index;
      const e = s + m[0].length;
      if (s <= pos.character && pos.character <= e) {
        return new Range(new Position(pos.line, s), new Position(pos.line, e));
      }
      if (s > pos.character) break;
    }
    return undefined;
  }

  // Applies LSP contentChanges in order; each one is relative to the text produced
  // by the previous one, as the protocol requires.
  _applyChanges(changes, version) {
    const events = [];
    for (const change of changes) {
      if (change.range) {
        const { Range, Position } = T();
        const range = new Range(
          new Position(change.range.start.line, change.range.start.character),
          new Position(change.range.end.line, change.range.end.character)
        );
        const startOffset = this.offsetAt(range.start);
        const endOffset = this.offsetAt(range.end);
        this._text = this._text.slice(0, startOffset) + change.text + this._text.slice(endOffset);
        this._lineStarts = null;
        events.push({ range, rangeOffset: startOffset, rangeLength: endOffset - startOffset, text: change.text });
      } else {
        const { Range, Position } = T();
        const old = this._text;
        const endPos = this.positionAt(old.length);
        this._text = change.text;
        this._lineStarts = null;
        events.push({
          range: new Range(new Position(0, 0), endPos),
          rangeOffset: 0,
          rangeLength: old.length,
          text: change.text,
        });
      }
    }
    if (typeof version === "number") this._version = version;
    this._isDirty = true;
    return events;
  }

  _setText(text, version) {
    this._text = text;
    this._lineStarts = null;
    if (typeof version === "number") this._version = version;
  }
}

class Documents {
  constructor(log) {
    this._log = log || (() => {});
    this._docs = new Map(); // uri string -> TextDocument (synced by the client)
    this._external = new Map(); // uri string -> TextDocument (read from disk)
    this._listeners = { open: [], change: [], close: [], save: [], willSave: [] };
    this.languageForPath = null; // set by vscode.js: fsPath -> language id
  }

  on(event, fn) {
    this._listeners[event].push(fn);
    return () => {
      const i = this._listeners[event].indexOf(fn);
      if (i >= 0) this._listeners[event].splice(i, 1);
    };
  }

  _emit(event, payload) {
    for (const fn of this._listeners[event].slice()) {
      try {
        const r = fn(payload);
        if (r && typeof r.then === "function") r.catch((e) => this._log("error", "document listener failed: " + (e && e.stack || e)));
      } catch (e) {
        this._log("error", "document listener failed: " + (e && e.stack || e));
      }
    }
  }

  get(uri) {
    const key = typeof uri === "string" ? uri : uri.toString();
    return this._docs.get(key) || this._external.get(key);
  }

  all() {
    return [...this._docs.values(), ...this._external.values()];
  }

  // textDocument/didOpen
  open(params) {
    const td = params.textDocument;
    const key = td.uri;
    let doc = this._docs.get(key);
    if (doc) {
      doc._languageId = td.languageId || doc._languageId;
      doc._setText(td.text || "", td.version);
      return doc;
    }
    const ext = this._external.get(key);
    if (ext) {
      // The client now owns a document the extension had read from disk: keep the
      // same object so the extension's references stay valid.
      this._external.delete(key);
      ext._external = false;
      ext._languageId = td.languageId || ext._languageId;
      ext._setText(td.text || "", td.version);
      ext._isClosed = false;
      this._docs.set(key, ext);
      this._emit("open", ext);
      return ext;
    }
    doc = new TextDocument(td.uri, td.languageId, td.version, td.text);
    this._docs.set(key, doc);
    this._emit("open", doc);
    return doc;
  }

  // textDocument/didChange
  change(params) {
    const doc = this._docs.get(params.textDocument.uri);
    if (!doc) {
      this._log("warn", "didChange for a document that is not open: " + params.textDocument.uri);
      return null;
    }
    const contentChanges = doc._applyChanges(params.contentChanges || [], params.textDocument.version);
    this._emit("change", { document: doc, contentChanges, reason: undefined });
    return doc;
  }

  // textDocument/didClose
  close(params) {
    const key = params.textDocument.uri;
    const doc = this._docs.get(key);
    if (!doc) return null;
    this._docs.delete(key);
    doc._isClosed = true;
    this._emit("close", doc);
    return doc;
  }

  // textDocument/didSave
  save(params) {
    const doc = this._docs.get(params.textDocument.uri);
    if (!doc) return null;
    if (typeof params.text === "string") doc._setText(params.text);
    doc._isDirty = false;
    this._emit("save", doc);
    return doc;
  }

  // textDocument/willSave
  willSave(params) {
    const doc = this._docs.get(params.textDocument.uri);
    if (!doc) return null;
    this._emit("willSave", { document: doc, reason: params.reason || 1 });
    return doc;
  }

  // workspace.openTextDocument for a file the client has not opened: read it once,
  // remember it, and let didOpen adopt it later.
  openExternal(uri) {
    const key = uri.toString();
    const existing = this.get(key);
    if (existing) return existing;
    if (uri.scheme !== "file") return null;
    const text = fs.readFileSync(uri.fsPath, "utf8");
    const languageId = (this.languageForPath && this.languageForPath(uri.fsPath)) || "plaintext";
    const doc = new TextDocument(uri, languageId, 0, text, { external: true });
    this._external.set(key, doc);
    this._emit("open", doc);
    return doc;
  }

  // workspace.openTextDocument({ content, language })
  openUntitled(content, language) {
    const { Uri } = T();
    const n = (this._untitledCount = (this._untitledCount || 0) + 1);
    const uri = Uri.parse("untitled:Untitled-" + n);
    const doc = new TextDocument(uri, language || "plaintext", 0, content || "", { external: true });
    this._external.set(uri.toString(), doc);
    this._emit("open", doc);
    return doc;
  }
}

module.exports = { TextDocument, Documents };
