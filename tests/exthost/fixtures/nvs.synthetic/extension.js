"use strict";
// A synthetic VS Code extension for tests/exthost/run.mjs. CommonJS, like most
// extensions built with tsc or esbuild's cjs output. Every feature it registers is
// checked by run.mjs; keep the two in step.
const vscode = require("vscode");

const PLAIN = { language: "plaintext" };

function greeting() {
  // Read on every use, so a settings change reaches the provider without a restart.
  return vscode.workspace.getConfiguration("synthetic").get("greeting", "hi");
}

function activate(context) {
  const out = vscode.window.createOutputChannel("Synthetic");
  out.appendLine("activated");
  out.appendLine(vscode.l10n.t("hello {0}", "world"));

  // Both of these must end up in the host's log, never on stdout.
  console.log("noise from console.log");
  process.stdout.write("raw noise on stdout\n");

  // Completion with trigger characters and a resolve step.
  context.subscriptions.push(
    vscode.languages.registerCompletionItemProvider(
      PLAIN,
      {
        provideCompletionItems(document, position, token, ctx) {
          const item = new vscode.CompletionItem("greeting", vscode.CompletionItemKind.Snippet);
          item.insertText = new vscode.SnippetString(greeting() + " ${1:name}");
          item.detail = "from synthetic";
          item.documentation = new vscode.MarkdownString("**bold** doc");
          const trigger = new vscode.CompletionItem("trigger:" + (ctx.triggerCharacter || "none"), vscode.CompletionItemKind.Text);
          const flags = vscode.workspace.getConfiguration("synthetic").get("flags");
          const flagsItem = new vscode.CompletionItem("flags:" + JSON.stringify(flags), vscode.CompletionItemKind.Value);
          return new vscode.CompletionList([item, trigger, flagsItem], false);
        },
        resolveCompletionItem(item) {
          item.detail = "resolved";
          return item;
        },
      },
      ".",
      "@"
    )
  );

  // Hover over the word under the cursor.
  context.subscriptions.push(
    vscode.languages.registerHoverProvider("plaintext", {
      provideHover(document, position) {
        const range = document.getWordRangeAtPosition(position);
        if (!range) return undefined;
        return new vscode.Hover(new vscode.MarkdownString("word: `" + document.getText(range) + "`"), range);
      },
    })
  );

  // Diagnostics: every TODO is a warning, updated on open and change.
  const collection = vscode.languages.createDiagnosticCollection("synthetic");
  function lint(document) {
    if (document.languageId !== "plaintext") return;
    const diagnostics = [];
    const text = document.getText();
    const re = /TODO/g;
    let m;
    while ((m = re.exec(text))) {
      const d = new vscode.Diagnostic(new vscode.Range(document.positionAt(m.index), document.positionAt(m.index + 4)), "todo found", vscode.DiagnosticSeverity.Warning);
      d.source = "synthetic";
      d.code = "todo";
      diagnostics.push(d);
    }
    collection.set(document.uri, diagnostics);
  }
  context.subscriptions.push(
    collection,
    vscode.workspace.onDidOpenTextDocument(lint),
    vscode.workspace.onDidChangeTextDocument((e) => lint(e.document)),
    vscode.workspace.onDidCloseTextDocument((d) => collection.delete(d.uri))
  );
  vscode.workspace.textDocuments.forEach(lint);

  // A command that returns a value, shows a message, reports progress and
  // remembers its arguments in globalState.
  context.subscriptions.push(
    vscode.commands.registerCommand("synthetic.echo", async (...args) => {
      await vscode.window.withProgress({ location: vscode.ProgressLocation.Notification, title: "Echoing" }, async (progress) => {
        progress.report({ message: "half", increment: 50 });
      });
      vscode.window.showInformationMessage("echo " + JSON.stringify(args));
      await context.globalState.update("lastEcho", args);
      return { echoed: args, greeting: greeting(), folders: (vscode.workspace.workspaceFolders || []).length };
    })
  );

  // Formatting: strip trailing whitespace from every line.
  context.subscriptions.push(
    vscode.languages.registerDocumentFormattingEditProvider(PLAIN, {
      provideDocumentFormattingEdits(document) {
        const edits = [];
        for (let i = 0; i < document.lineCount; i++) {
          const line = document.lineAt(i);
          const m = /\s+$/.exec(line.text);
          if (m) edits.push(vscode.TextEdit.delete(new vscode.Range(i, m.index, i, line.text.length)));
        }
        return edits;
      },
    })
  );

  // A code action that fixes a TODO diagnostic through a WorkspaceEdit.
  context.subscriptions.push(
    vscode.languages.registerCodeActionsProvider(
      PLAIN,
      {
        provideCodeActions(document, range, ctx) {
          return ctx.diagnostics
            .filter((d) => d.code === "todo")
            .map((d) => {
              const action = new vscode.CodeAction("Mark done", vscode.CodeActionKind.QuickFix);
              action.diagnostics = [d];
              action.edit = new vscode.WorkspaceEdit();
              action.edit.replace(document.uri, d.range, "DONE");
              return action;
            });
        },
      },
      { providedCodeActionKinds: [vscode.CodeActionKind.QuickFix] }
    )
  );

  // Registered after activate returns: the host must announce it dynamically.
  setTimeout(() => {
    context.subscriptions.push(
      vscode.languages.registerDefinitionProvider("plaintext", {
        provideDefinition(document) {
          return new vscode.Location(document.uri, new vscode.Position(0, 0));
        },
      })
    );
  }, 200);

  // A status bar item and a member the host does not implement.
  const status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 1);
  status.text = "Synthetic ready";
  status.show();
  context.subscriptions.push(status);
  vscode.window.createTreeView("synthetic.view", { treeDataProvider: {} });

  return { api: "synthetic" };
}

function deactivate() {}

module.exports = { activate, deactivate };
