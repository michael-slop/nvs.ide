// stub-server.js: the smallest language server that satisfies Neovim's LSP client.
//
// make_vsix.lua copies it into the synthetic .vsix fixtures in place of every .js file
// the real archives ship (server bundles, extension entry points), so the tests can
// prove that a bundled server is started with `node <server> --stdio` and attaches,
// without committing megabytes of third-party code. It answers initialize, shutdown,
// exit and hover; every other request gets a "not implemented" error.
"use strict";

let pending = Buffer.alloc(0);

function send(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  process.stdout.write("Content-Length: " + body.length + "\r\n\r\n");
  process.stdout.write(body);
}

function handle(msg) {
  if (msg.method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: msg.id,
      result: {
        capabilities: { textDocumentSync: 1, hoverProvider: true },
        serverInfo: { name: "nvs-stub-server", version: "0" },
      },
    });
  } else if (msg.method === "shutdown") {
    send({ jsonrpc: "2.0", id: msg.id, result: null });
  } else if (msg.method === "exit") {
    process.exit(0);
  } else if (msg.method === "textDocument/hover") {
    send({ jsonrpc: "2.0", id: msg.id, result: { contents: "nvs stub server" } });
  } else if (msg.id !== undefined) {
    send({ jsonrpc: "2.0", id: msg.id, error: { code: -32601, message: "not implemented: " + msg.method } });
  }
}

process.stdin.on("data", (chunk) => {
  pending = Buffer.concat([pending, chunk]);
  for (;;) {
    const headerEnd = pending.indexOf("\r\n\r\n");
    if (headerEnd < 0) {
      return;
    }
    const header = pending.subarray(0, headerEnd).toString("ascii");
    const m = /Content-Length:\s*(\d+)/i.exec(header);
    if (!m) {
      pending = pending.subarray(headerEnd + 4);
      continue;
    }
    const length = parseInt(m[1], 10);
    if (pending.length < headerEnd + 4 + length) {
      return;
    }
    const body = pending.subarray(headerEnd + 4, headerEnd + 4 + length).toString("utf8");
    pending = pending.subarray(headerEnd + 4 + length);
    let msg;
    try {
      msg = JSON.parse(body);
    } catch (e) {
      continue;
    }
    handle(msg);
  }
});

process.stdin.on("end", () => process.exit(0));
