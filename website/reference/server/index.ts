import cors from "cors";
import express from "express";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const app = express();

app.use(cors());
app.use(express.json({ limit: "1mb" }));

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "../../..");
const funBinary = path.join(repoRoot, "zig-out/bin/fun");
const stdlibDir = path.join(repoRoot, "stdlib");
const webDist = path.resolve(__dirname, "../dist");

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, compiler: funBinary });
});

app.post("/api/run", async (req, res) => {
  const code = String(req.body?.code ?? "").trim();
  if (!code) {
    res.status(400).json({ ok: false, error: "No code provided." });
    return;
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "fun-ref-"));
  const srcPath = path.join(tempDir, "snippet.fn");

  try {
    await fs.access(funBinary);
  } catch {
    await fs.rm(tempDir, { recursive: true, force: true });
    res.status(500).json({
      ok: false,
      error:
        "Compiler binary not found at zig-out/bin/fun. Run `zig build` from repository root first.",
    });
    return;
  }

  try {
    await fs.writeFile(srcPath, `${code}\n`, "utf8");

    const { stdout, stderr } = await execFileAsync(
      funBinary,
      ["-in", srcPath],
      {
        cwd: repoRoot,
        env: {
          ...process.env,
          FUN_STDLIB_DIR: stdlibDir,
        },
        timeout: 10000,
        maxBuffer: 1024 * 1024,
      },
    );

    res.json({
      ok: true,
      stdout,
      stderr,
    });
  } catch (error: any) {
    res.status(200).json({
      ok: false,
      stdout: error?.stdout ?? "",
      stderr: error?.stderr ?? error?.message ?? "Execution failed",
    });
  } finally {
    await fs.rm(tempDir, { recursive: true, force: true });
  }
});

if (process.env.NODE_ENV === "production") {
  app.use(express.static(webDist));
  app.get("*", (_req, res) => {
    res.sendFile(path.join(webDist, "index.html"));
  });
}

const port = Number(process.env.PORT ?? 8787);
app.listen(port, () => {
  console.log(`Fun reference server running at http://localhost:${port}`);
});
