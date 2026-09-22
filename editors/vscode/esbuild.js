// Bundles src/extension.ts into a single out/extension.js: everything
// this extension actually uses from vscode-languageclient and its own
// transitive dependencies gets inlined, instead of shipping ~180 loose
// unbundled files from node_modules in the .vsix (vsce warns about this
// directly: https://aka.ms/vscode-bundle-extension). `vscode` itself
// stays external - the host injects it, and it isn't resolvable outside
// a real extension host anyway.
const esbuild = require("esbuild");

const production = process.argv.includes("--production");
const watch = process.argv.includes("--watch");

async function main() {
  const ctx = await esbuild.context({
    entryPoints: ["src/extension.ts"],
    bundle: true,
    format: "cjs",
    platform: "node",
    target: "node20",
    outfile: "out/extension.js",
    external: ["vscode"],
    sourcemap: !production,
    minify: production,
    logLevel: "info",
  });
  if (watch) {
    await ctx.watch();
  } else {
    await ctx.rebuild();
    await ctx.dispose();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
