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

function workspaceFilePath() {
  const file = vscode.workspace.workspaceFile;
  if (!file) {
    return "";
  }
  if (file.scheme === "file") {
    return normalize(file.fsPath);
  }
  return "";
}

function workspaceFileHint() {
  const file = vscode.workspace.workspaceFile;
  if (!file) {
    return "(none)";
  }
  return `${file.scheme}:${file.fsPath || file.path || file.toString()}`;
}

function stripWorkspaceSuffix(name) {
  return String(name || "")
    .replace(/\.code-workspace$/i, "")
    .replace(/ \((?:工作区|Workspace)\)$/i, "")
    .trim();
}

function samePath(left, right) {
  const a = normalize(left).toLowerCase();
  const b = normalize(right).toLowerCase();
  if (!a || !b) {
    return false;
  }
  if (a === b) {
    return true;
  }
  try {
    return fs.realpathSync.native(left) === fs.realpathSync.native(right);
  } catch (realPathError) {
    return false;
  }
}

function readWorkspaceMembers(workspaceFile) {
  try {
    const json = JSON.parse(fs.readFileSync(workspaceFile, "utf8"));
    const folders = json.folders || [];
    const baseDir = path.dirname(workspaceFile);
    return folders
      .map((folder) => {
        const raw = folder.path;
        if (!raw) {
          return "";
        }
        if (raw.startsWith("file://")) {
          try {
            return normalize(decodeURIComponent(raw.replace(/^file:\/\//, "")));
          } catch (decodeError) {
            return "";
          }
        }
        if (path.isAbsolute(raw)) {
          return normalize(raw);
        }
        return normalize(path.resolve(baseDir, raw));
      })
      .filter(Boolean);
  } catch (readWorkspaceError) {
    return [];
  }
}

function sameFolderSet(left, right) {
  if (left.length === 0 || left.length !== right.length) {
    return false;
  }
  const rightSet = new Set(right.map((item) => normalize(item).toLowerCase()));
  return left.every((item) => rightSet.has(normalize(item).toLowerCase()));
}

function matches(request, mine) {
  const target = normalize(request.path || "");
  const isWorkspace =
    request.isWorkspace === true || target.toLowerCase().endsWith(".code-workspace");
  const wsFile = workspaceFilePath();
  const currentName = stripWorkspaceSuffix(vscode.workspace.name || "");
  const wantName = stripWorkspaceSuffix(request.name || path.basename(target));

  if (isWorkspace) {
    if (wsFile && (samePath(wsFile, target) || path.basename(wsFile).toLowerCase() === path.basename(target).toLowerCase())) {
      return true;
    }
    if (currentName && wantName && currentName.toLowerCase() === wantName.toLowerCase() && mine.length >= 2) {
      return true;
    }
    const members = readWorkspaceMembers(target);
    if (members.length >= 2 && sameFolderSet(members, mine)) {
      return true;
    }
    return false;
  }

  if (mine.some((item) => samePath(item, target))) {
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

const skipLogged = new Set();

function tryClose() {
  const request = readRequest();
  if (!request || !request.path || request.done) {
    return;
  }
  const target = normalize(request.path);
  const mine = workspacePaths();
  if (!matches(request, mine)) {
    if (request.isWorkspace && request.id && !skipLogged.has(request.id)) {
      skipLogged.add(request.id);
      log(
        `skip workspace target=${target} want=${request.name || ""} haveName=${vscode.workspace.name || ""} mine=${mine.join(",") || "(none)"} workspaceFile=${workspaceFileHint()}`
      );
    }
    return;
  }
  const claimed = {
    ...request,
    done: true,
    claimedBy: workspaceFilePath() || mine[0] || target,
    claimedName: vscode.workspace.name || "",
  };
  try {
    fs.writeFileSync(requestPath, JSON.stringify(claimed));
  } catch (writeClaimError) {
    log(`claim failed ${writeClaimError}`);
    return;
  }
  log(
    `closing ${target} name=${request.name || ""} mine=${mine.join(",")} workspaceFile=${workspaceFileHint()}`
  );
  vscode.commands.executeCommand("workbench.action.closeWindow");
}

function activate() {
  log(
    `activate folders=${workspacePaths().join(",") || "(none)"} workspaceFile=${workspaceFileHint()} name=${vscode.workspace.name || "(none)"}`
  );
  tryClose();
  setInterval(tryClose, 250);
}

function deactivate() {}

module.exports = { activate, deactivate };
