import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

// Node's native TypeScript stripping intentionally does not implement the
// bundler-style extensionless resolution used by the Worker. Bundle the exact
// production modules first, run them, then remove only this process's temp file.
const outfile = join(tmpdir(), `scenefind-episode-regression-${process.pid}.mjs`);
const entryPoint = fileURLToPath(new URL("run-tiktok-episode-regression.ts", import.meta.url));

try {
  await build({
    entryPoints: [entryPoint],
    outfile,
    bundle: true,
    platform: "node",
    format: "esm",
    logLevel: "warning",
  });
  await import(pathToFileURL(outfile).href);
} finally {
  await rm(outfile, { force: true });
}
