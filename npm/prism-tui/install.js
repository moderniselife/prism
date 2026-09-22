// Postinstall: fetch the matching static binary from GitHub releases.
// No runtime dependencies — uses only Node built-ins + system tar/PowerShell.
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");

const pkg = require("./package.json");

const OS_MAP = { darwin: "darwin", linux: "linux", win32: "windows" };
const ARCH_MAP = { arm64: "arm64", x64: "amd64" };

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

async function main() {
  if (process.env.PRISM_TUI_SKIP_DOWNLOAD) {
    console.log("prism-tui: skipping binary download (PRISM_TUI_SKIP_DOWNLOAD set)");
    return;
  }
  const version = pkg.version;
  if (!version || version === "0.0.0-dev") {
    console.log("prism-tui: dev checkout — skipping download; build ./tui yourself");
    return;
  }
  const osName = OS_MAP[process.platform];
  const arch = ARCH_MAP[process.arch];
  if (!osName || !arch) {
    throw new Error(`unsupported platform: ${process.platform}/${process.arch}`);
  }
  const isWin = osName === "windows";
  const asset = `prism-tui-${osName}-${arch}.${isWin ? "zip" : "tar.gz"}`;
  // Release tags look like tui-v1.2.3; the tag is stamped into package.json
  // at publish time (see .github/workflows/release.yml).
  const tag = pkg.prism && pkg.prism.releaseTag ? pkg.prism.releaseTag : `v${version}`;
  const url = `https://github.com/${pkg.prism.repo}/releases/download/${tag}/${asset}`;

  const dir = path.join(__dirname, "binaries");
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "prism-tui-")), asset);
  console.log(`prism-tui: downloading ${asset} ...`);
  await download(url, tmp);

  if (isWin) {
    execFileSync("powershell", [
      "-NoProfile", "-Command",
      `Expand-Archive -Force '${tmp}' '${dir}'`,
    ], { stdio: "inherit" });
  } else {
    execFileSync("tar", ["-xzf", tmp, "-C", dir]);
    fs.chmodSync(path.join(dir, "prism-tui"), 0o755);
  }
  fs.rmSync(tmp, { force: true });
  console.log("prism-tui: installed");
}

main().catch((err) => {
  console.error("prism-tui postinstall failed:", err.message);
  process.exit(1);
});
