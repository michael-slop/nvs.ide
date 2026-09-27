"use strict";
// activate() awaits a client request before it registers anything: the shape that used to
// hold initialize for the full activation timeout (20 s).
const vscode = require("vscode");

async function activate(context) {
  await vscode.workspace.applyEdit(new vscode.WorkspaceEdit());
  context.subscriptions.push(
    vscode.languages.registerHoverProvider("plaintext", {
      provideHover: () => new vscode.Hover("gated hover"),
    })
  );
}

module.exports = { activate };
