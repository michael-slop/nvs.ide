"use strict";
// A provider that never looks at its CancellationToken, as plenty of real ones don't.
const vscode = require("vscode");

function activate(context) {
  context.subscriptions.push(
    vscode.languages.registerHoverProvider("plaintext", {
      provideHover: () => new Promise((resolve) => setTimeout(() => resolve(new vscode.Hover("late")), 8000)),
    })
  );
}

module.exports = { activate };
