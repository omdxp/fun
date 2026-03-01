import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const siteRoot = path.resolve(__dirname, "..");
const repoRoot = path.resolve(siteRoot, "../..");

async function readFunVersion() {
  const zon = await fs.readFile(path.join(repoRoot, "build.zig.zon"), "utf8");
  const m = zon.match(/\.version\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("Could not parse .version from build.zig.zon");
  return m[1];
}

const rawVersion = process.env.FUN_VERSION || (await readFunVersion());
const version = rawVersion.startsWith("v") ? rawVersion.slice(1) : rawVersion;
const pkgPath = path.join(siteRoot, "package.json");
const pkg = JSON.parse(await fs.readFile(pkgPath, "utf8"));
pkg.version = version;
await fs.writeFile(pkgPath, `${JSON.stringify(pkg, null, 2)}\n`, "utf8");

console.log(`Synced website version to ${version}`);
