"use strict";
// JSON-RPC 2.0 over a byte stream with LSP's Content-Length framing.
//
// The connection owns the only writer to the output stream. host.js hands it
// process.stdout's original write function before replacing process.stdout.write
// with a logger, so nothing an extension does can put stray bytes between frames.

const { EventEmitter } = require("events");

const ErrorCodes = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  ServerNotInitialized: -32002,
  UnknownErrorCode: -32001,
  RequestFailed: -32803,
  ServerCancelled: -32802,
  ContentModified: -32801,
  RequestCancelled: -32800,
};

class ResponseError extends Error {
  constructor(code, message, data) {
    super(message);
    this.name = "ResponseError";
    this.code = code;
    this.data = data;
  }
  toJSON() {
    const out = { code: this.code, message: this.message };
    if (this.data !== undefined) out.data = this.data;
    return out;
  }
}

// The cancellation handle a request handler receives. host.js wraps it in a
// vscode.CancellationTokenSource; keeping it plain here keeps lsp.js free of the shim.
class RequestContext {
  constructor(id, method) {
    this.id = id;
    this.method = method;
    this.cancelled = false;
    this.replied = false;
    this._listeners = [];
    this._respondCancelled = null; // set by the connection: answers RequestCancelled once
  }
  onCancel(fn) {
    if (this.cancelled) fn();
    else this._listeners.push(fn);
  }
  _cancel() {
    if (this.cancelled) return;
    this.cancelled = true;
    for (const fn of this._listeners.splice(0)) {
      try {
        fn();
      } catch (_) {
        // A cancel listener must not take the connection down.
      }
    }
    // The client gave up on this request, and the protocol says a cancelled request
    // still needs a response. A provider that ignores its token may never settle, so
    // the answer goes out now and whatever the handler produces later is dropped.
    if (this._respondCancelled) this._respondCancelled();
  }
}

class Connection extends EventEmitter {
  // input: a Readable (stdin). write: function(Buffer) that puts bytes on the wire.
  // log: function(level, message).
  constructor(input, write, log) {
    super();
    this._input = input;
    this._write = write;
    this._log = log || (() => {});
    this._buffer = Buffer.alloc(0);
    this._nextId = 1;
    this._pendingOut = new Map(); // id -> { resolve, reject, method }
    this._pendingIn = new Map(); // id -> RequestContext
    this._requestHandlers = new Map();
    this._notificationHandlers = new Map();
    this._closed = false;
  }

  listen() {
    this._input.on("data", (chunk) => this._onData(chunk));
    const close = () => {
      if (this._closed) return;
      this._closed = true;
      for (const p of this._pendingOut.values()) {
        p.reject(new ResponseError(ErrorCodes.InternalError, "connection closed"));
      }
      this._pendingOut.clear();
      this.emit("close");
    };
    this._input.on("end", close);
    this._input.on("close", close);
    this._input.on("error", (err) => {
      this._log("error", "stdin error: " + (err && err.message));
      close();
    });
    this._input.resume();
  }

  get closed() {
    return this._closed;
  }

  onRequest(method, handler) {
    this._requestHandlers.set(method, handler);
  }

  onNotification(method, handler) {
    this._notificationHandlers.set(method, handler);
  }

  sendRequest(method, params) {
    if (this._closed) {
      return Promise.reject(new ResponseError(ErrorCodes.InternalError, "connection closed"));
    }
    const id = this._nextId++;
    const message = { jsonrpc: "2.0", id, method };
    if (params !== undefined) message.params = params;
    return new Promise((resolve, reject) => {
      this._pendingOut.set(id, { resolve, reject, method });
      this._send(message);
    });
  }

  sendNotification(method, params) {
    if (this._closed) return;
    const message = { jsonrpc: "2.0", method };
    if (params !== undefined) message.params = params;
    this._send(message);
  }

  _send(message) {
    let body;
    try {
      body = JSON.stringify(message);
    } catch (err) {
      // A result that cannot be serialised (a cycle, a BigInt) must not kill the
      // connection; the client gets an error instead.
      if (message.id !== undefined && "result" in message) {
        body = JSON.stringify({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: ErrorCodes.InternalError, message: "result is not serialisable: " + err.message },
        });
      } else {
        this._log("error", "dropped unserialisable message for " + message.method + ": " + err.message);
        return;
      }
    }
    const bytes = Buffer.from(body, "utf8");
    const header = Buffer.from("Content-Length: " + bytes.length + "\r\n\r\n", "ascii");
    this._write(Buffer.concat([header, bytes]));
  }

  _onData(chunk) {
    this._buffer = this._buffer.length ? Buffer.concat([this._buffer, chunk]) : chunk;
    for (;;) {
      const headerEnd = this._buffer.indexOf("\r\n\r\n");
      if (headerEnd < 0) return;
      const header = this._buffer.subarray(0, headerEnd).toString("ascii");
      let length = -1;
      for (const line of header.split("\r\n")) {
        const colon = line.indexOf(":");
        if (colon < 0) continue;
        const name = line.slice(0, colon).trim().toLowerCase();
        if (name === "content-length") length = parseInt(line.slice(colon + 1).trim(), 10);
      }
      if (!(length >= 0)) {
        // Not a frame we understand. Drop up to the header end and resync rather than
        // stall forever on a header with no length.
        this._log("error", "frame without Content-Length: " + JSON.stringify(header.slice(0, 200)));
        this._buffer = this._buffer.subarray(headerEnd + 4);
        continue;
      }
      const bodyStart = headerEnd + 4;
      if (this._buffer.length < bodyStart + length) return;
      const body = this._buffer.subarray(bodyStart, bodyStart + length).toString("utf8");
      this._buffer = this._buffer.subarray(bodyStart + length);
      let message;
      try {
        message = JSON.parse(body);
      } catch (err) {
        this._log("error", "bad JSON from client: " + err.message);
        continue;
      }
      this._dispatch(message);
    }
  }

  _dispatch(message) {
    if (message === null || typeof message !== "object") return;
    if (message.method !== undefined) {
      if (message.id !== undefined && message.id !== null) this._handleRequest(message);
      else this._handleNotification(message);
      return;
    }
    if (message.id !== undefined) this._handleResponse(message);
  }

  _handleResponse(message) {
    const pending = this._pendingOut.get(message.id);
    if (!pending) {
      this._log("warn", "response for unknown request id " + message.id);
      return;
    }
    this._pendingOut.delete(message.id);
    if (message.error) {
      const e = message.error;
      pending.reject(new ResponseError(e.code, e.message, e.data));
    } else {
      pending.resolve(message.result === undefined ? null : message.result);
    }
  }

  _handleNotification(message) {
    if (message.method === "$/cancelRequest") {
      const ctx = message.params && this._pendingIn.get(message.params.id);
      if (ctx) ctx._cancel();
      return;
    }
    const handler = this._notificationHandlers.get(message.method);
    if (!handler) {
      if (!message.method.startsWith("$/")) this._log("debug", "unhandled notification " + message.method);
      return;
    }
    try {
      const r = handler(message.params);
      if (r && typeof r.then === "function") {
        r.catch((err) => this._log("error", "notification " + message.method + " failed: " + describe(err)));
      }
    } catch (err) {
      this._log("error", "notification " + message.method + " failed: " + describe(err));
    }
  }

  _handleRequest(message) {
    const { id, method } = message;
    const ctx = new RequestContext(id, method);
    // One response per request. After a cancel has been answered, a late result or
    // error from the handler is logged and dropped.
    const send = (payload, what) => {
      if (ctx.replied) {
        this._log("debug", "late " + what + " for cancelled request " + method + " (id " + id + ") dropped");
        return;
      }
      ctx.replied = true;
      this._pendingIn.delete(id);
      this._send(Object.assign({ jsonrpc: "2.0", id }, payload));
    };
    const reply = (result) => send({ result: result === undefined ? null : result }, "result");
    const fail = (error) => {
      let err;
      if (error instanceof ResponseError) err = error.toJSON();
      else err = { code: ErrorCodes.InternalError, message: describe(error) };
      send({ error: err }, "error");
    };
    const handler = this._requestHandlers.get(method);
    if (!handler) {
      if (method.startsWith("$/")) {
        // Optional protocol extensions may be answered with MethodNotFound, per spec.
        fail(new ResponseError(ErrorCodes.MethodNotFound, "unhandled method " + method));
      } else {
        this._log("warn", "no handler for request " + method);
        fail(new ResponseError(ErrorCodes.MethodNotFound, "unhandled method " + method));
      }
      return;
    }
    ctx._respondCancelled = () => fail(new ResponseError(ErrorCodes.RequestCancelled, "cancelled"));
    this._pendingIn.set(id, ctx);
    let outcome;
    try {
      outcome = handler(message.params, ctx);
    } catch (err) {
      this._log("error", "request " + method + " threw: " + describe(err));
      fail(ctx.cancelled ? new ResponseError(ErrorCodes.RequestCancelled, "cancelled") : err);
      return;
    }
    Promise.resolve(outcome).then(reply, (err) => {
      if (ctx.cancelled) {
        fail(new ResponseError(ErrorCodes.RequestCancelled, "cancelled"));
        return;
      }
      if (!(err instanceof ResponseError)) this._log("error", "request " + method + " failed: " + describe(err));
      fail(err);
    });
  }
}

function describe(err) {
  if (err instanceof Error) return err.stack || err.message;
  try {
    return typeof err === "string" ? err : JSON.stringify(err);
  } catch (_) {
    return String(err);
  }
}

module.exports = { Connection, ResponseError, ErrorCodes, describe };
