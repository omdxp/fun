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
const funBinary = path.join(repoRoot, "fun-out/bin/fun");
const stdlibDir = path.join(repoRoot, "stdlib");
const webDist = path.resolve(__dirname, "../dist");

const FILE_MARKER = /^\s*\/\/\s*file:\s*(.+?)\s*$/i;

type SnippetFile = {
  path: string;
  contents: string;
};

type ParsedSnippet = {
  files: SnippetFile[];
  entryFile: string;
};

type ParsedSnippetResult = ParsedSnippet | { error: string } | null;

function normalizeSnippetPath(rawPath: string) {
  const trimmed = rawPath.trim().replaceAll("\\", "/");
  if (!trimmed) return null;
  if (path.isAbsolute(trimmed)) return null;
  const normalized = path.normalize(trimmed).replaceAll("\\", "/");
  if (normalized.startsWith("..") || normalized.includes("/..")) return null;
  if (!normalized.endsWith(".fn")) return null;
  return normalized;
}

function parseSnippetFiles(code: string): ParsedSnippetResult {
  const lines = code.split(/\r?\n/);
  const files: SnippetFile[] = [];
  let currentPath = "snippet.fn";
  let currentLines: string[] = [];
  let sawMarker = false;

  const flush = () => {
    if (currentLines.length === 0) return;
    files.push({
      path: currentPath,
      contents: `${currentLines.join("\n")}\n`,
    });
  };

  for (const line of lines) {
    const marker = line.match(FILE_MARKER);
    if (marker) {
      flush();
      const nextPath = normalizeSnippetPath(marker[1] ?? "");
      if (!nextPath) {
        return {
          error:
            "Invalid file marker. Use // file: path/to/name.fn (no absolute paths or ..).",
        };
      }
      currentPath = nextPath;
      currentLines = [];
      sawMarker = true;
      continue;
    }
    currentLines.push(line);
  }

  flush();

  if (!sawMarker) return null;
  if (files.length === 0) {
    return { error: "No file contents found after file markers." };
  }

  const entry =
    files.find(
      (file) => file.path === "main.fn" || file.path.endsWith("/main.fn"),
    )?.path ?? files[0].path;

  return { files, entryFile: entry };
}

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, compiler: funBinary });
});

app.post("/api/run", async (req, res) => {
  const rawCode = String(req.body?.code ?? "");
  if (!rawCode.trim()) {
    res.status(400).json({ ok: false, error: "No code provided." });
    return;
  }

  const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "fun-ref-"));
  let srcPath = path.join(tempDir, "snippet.fn");

  try {
    await fs.access(funBinary);
  } catch {
    await fs.rm(tempDir, { recursive: true, force: true });
    res.status(500).json({
      ok: false,
      error:
        "Compiler binary not found at fun-out/bin/fun. Run `fun build` from repository root first.",
    });
    return;
  }

  try {
    const parsed = parseSnippetFiles(rawCode);
    if (parsed && "error" in parsed) {
      res.status(400).json({ ok: false, error: parsed.error });
      return;
    }

    if (parsed && "files" in parsed) {
      for (const file of parsed.files) {
        const fullPath = path.join(tempDir, file.path);
        await fs.mkdir(path.dirname(fullPath), { recursive: true });
        await fs.writeFile(fullPath, file.contents, "utf8");
      }
      srcPath = path.join(tempDir, parsed.entryFile);
    } else {
      await fs.writeFile(srcPath, `${rawCode.trimEnd()}\n`, "utf8");
    }

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
