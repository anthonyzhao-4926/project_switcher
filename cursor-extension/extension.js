const fs = require("fs");
const os = require("os");
const path = require("path");
const vscode = require("vscode");

const supportDir = path.join(os.homedir(), "Library/Application Support/ProjectSwitcher");
const requestPath = path.join(supportDir, "close-request.json");
const logPath = path.join(supportDir, "close-extension.log");

function log(message) {
  try {
    fs.mkdirSync(supportDir, { recursive: true });
    fs.appendFileSync(logPath, `${new Date().toISOString()} ${message}\n`);
  } catch (logError) {
    // ignore
  }
}

function normalize(p) {
  if (!p) {
    return "";
  }
  return path.normalize(p).replace(/\/+$/, "");
}

function workspacePaths() {
  const folders = vscode.workspace.workspaceFolders || [];
  return folders.map((folder) => normalize(folder.uri.fsPath)).filter(Boolean);
}

function matches(target, mine) {
  if (mine.includes(target)) {
    return true;
  }
  const targetName = path.basename(target).toLowerCase();
  return mine.some((item) => path.basename(item).toLowerCase() === targetName);
}

function readRequest() {
  try {
    return JSON.parse(fs.readFileSync(requestPath, "utf8"));
  } catch (readRequestError) {
    return null;
  }
}

function tryClose() {
  const request = readRequest();
  if (!request || !request.path || request.done) {
    return;
  }
  const target = normalize(request.path);
  const mine = workspacePaths();
  if (!matches(target, mine)) {
    return;
  }
  const claimed = {
    ...request,
    done: true,
    claimedBy: mine[0] || target,
  };
  try {
    fs.writeFileSync(requestPath, JSON.stringify(claimed));
  } catch (writeClaimError) {
    log(`claim failed ${writeClaimError}`);
    return;
  }
  log(`closing ${target} mine=${mine.join(",")}`);
  vscode.commands.executeCommand("workbench.action.closeWindow");
}

function activate() {
  log(`activate folders=${workspacePaths().join(",") || "(none)"}`);
  tryClose();
  setInterval(tryClose, 250);
}

function deactivate() {}

module.exports = { activate, deactivate };
