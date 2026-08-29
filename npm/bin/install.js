#!/usr/bin/env node
// Installs Quill.app from the packaged zip into /Applications
// (falls back to ~/Applications if /Applications isn't writable).
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const zip = path.join(__dirname, "..", "Quill.app.zip");
if (process.platform !== "darwin") {
  console.error("Quill is a macOS app; skipping install.");
  process.exit(0);
}
if (!fs.existsSync(zip)) {
  console.error("Quill.app.zip missing from package; aborting.");
  process.exit(1);
}

let dest = "/Applications";
try {
  fs.accessSync(dest, fs.constants.W_OK);
} catch {
  dest = path.join(os.homedir(), "Applications");
  fs.mkdirSync(dest, { recursive: true });
}

const appPath = path.join(dest, "Quill.app");
if (fs.existsSync(appPath)) fs.rmSync(appPath, { recursive: true, force: true });
// ditto preserves the code signature and resource forks.
execFileSync("ditto", ["-x", "-k", zip, dest], { stdio: "inherit" });
console.log(`Quill installed to ${appPath}`);
console.log("First launch: right-click Quill.app -> Open (alpha is ad-hoc signed).");
