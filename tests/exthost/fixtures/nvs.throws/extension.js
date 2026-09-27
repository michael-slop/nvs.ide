"use strict";
// Registers a provider and then throws, so the test can see that nothing it
// registered is announced once activation fails.
const vscode = require("vscode");

function activate() {
  vscode.languages.registerHoverProvider("plaintext", { provideHover: () => undefined });
  throw new Error("boom: activate failed on purpose");
}

module.exports = { activate };
