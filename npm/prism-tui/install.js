// Fetches the matching static binary from GitHub releases.
// Runs as the postinstall script, and again from the launcher on first run
// when the postinstall didn't (npm can be set to skip install scripts).
// No runtime dependencies: Node built-ins plus the system tar/PowerShell.
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const pkg = require("./package.json");

const OS_MAP = { darwin: "darwin", linux: "linux", win32: "windows" };
const ARCH_MAP = { arm64: "arm64", x64: "amd64" };
const EXE = process.platform === "win32" ? "prism-tui.exe" : "prism-tui";

// Where the binary can live: next to the package, or, when the package
// folder isn't writable (a global install owned by root), a per-user cache.
function candidateDirs() {
  const cacheRoot =
    process.platform === "win32"
      ? process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local")
      : process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
  return [
    path.join(__dirname, "binaries"),
    path.join(cacheRoot, "prism-tui", pkg.version),
  ];
}

function findBinary() {
  for (const dir of candidateDirs()) {
    const bin = path.join(dir, EXE);
    if (fs.existsSync(bin)) return bin;
  }
  return null;
}

function download(url, dest) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      url,
      { headers: { "User-Agent": "prism-tui-installer" } },
      (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return resolve(download(res.headers.location, dest));
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
        }
        const out = fs.createWriteStream(dest);
        res.pipe(out);
        out.on("finish", () => resolve());
        out.on("error", reject);
      }
    );
    req.on("error", reject);
  });
}

function writableDir() {
  for (const dir of candidateDirs()) {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.accessSync(dir, fs.constants.W_OK);
      return dir;
    } catch {
      // try the next one
    }
  }
  throw new Error("no writable folder for the prism-tui binary");
}

// Downloads the binary if it isn't there yet and returns its path, or null
// for a dev checkout or when PRISM_TUI_SKIP_DOWNLOAD is set.
async function install({ quiet = false } = {}) {
  const log = quiet ? () => {} : (msg) => console.error(msg);
  const existing = findBinary();
  if (existing) return existing;
  if (process.env.PRISM_TUI_SKIP_DOWNLOAD) {
    log("prism-tui: skipping binary download (PRISM_TUI_SKIP_DOWNLOAD set)");
    return null;
  }
  const version = pkg.version;
  if (!version || version === "0.0.0-dev") {
    log("prism-tui: dev checkout, skipping download; build ./tui yourself");
    return null;
  }
  const osName = OS_MAP[process.platform];
  const arch = ARCH_MAP[process.arch];
  if (!osName || !arch) {
    throw new Error(`unsupported platform: ${process.platform}/${process.arch}`);
  }
  const isWin = osName === "windows";
  const asset = `prism-tui-${osName}-${arch}.${isWin ? "zip" : "tar.gz"}`;
  // Release tags look like v1.2.3; the tag is stamped into package.json
  // at publish time (see .github/workflows/release.yml).
  const tag = pkg.prism && pkg.prism.releaseTag ? pkg.prism.releaseTag : `v${version}`;
  const url = `https://github.com/${pkg.prism.repo}/releases/download/${tag}/${asset}`;

  const dir = writableDir();
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "prism-tui-"));
  const tmp = path.join(tmpDir, asset);
  log(`prism-tui: downloading ${asset} …`);
  try {
    await download(url, tmp);
    if (isWin) {
      execFileSync("powershell", [
        "-NoProfile", "-Command",
        `Expand-Archive -Force '${tmp}' '${dir}'`,
      ], { stdio: "inherit" });
    } else {
      execFileSync("tar", ["-xzf", tmp, "-C", dir]);
      fs.chmodSync(path.join(dir, EXE), 0o755);
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
  log("prism-tui: installed");
  return path.join(dir, EXE);
}

module.exports = { install, findBinary };

if (require.main === module) {
  install().catch((err) => {
    // Don't fail the npm install: the launcher retries on first run.
    console.error("prism-tui: couldn't download the binary yet:", err.message);
    console.error("prism-tui: it will try again the first time you run prism-tui.");
  });
}
