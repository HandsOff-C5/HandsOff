// Self-host the MediaPipe assets the HandsOff camera shell loads at runtime (#25).
//
// Tauri serves the frontend from tauri://localhost and the dev COOP/COEP headers
// (require-corp) block cross-origin CDN fetches — so the wasm runtime AND the
// MediaPipe models must be served locally from public/. This script:
//   1. copies the @mediapipe/tasks-vision `wasm/` dir → public/wasm
//   2. downloads hand_landmarker.task + face_landmarker.task → public/models
//      (each skipped if already present)
// Both outputs are gitignored (binaries, ~10MB+); run this once before `tauri dev`.
//
// Run: pnpm --filter @handsoff/desktop-app setup:assets
import { cpSync, existsSync, mkdirSync, createWriteStream } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { get } from "node:https";
import process from "node:process";

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const publicDir = join(here, "..", "public");

const log = (msg) => process.stdout.write(`${msg}\n`);

// Pinned to the @mediapipe/tasks-vision version in package.json. float16 is the
// standard web build. The face model is the iris-refined 478-point Face Landmarker.
const MODELS = [
  {
    name: "hand_landmarker.task",
    url: "https://storage.googleapis.com/mediapipe-models/hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task",
  },
  {
    name: "face_landmarker.task",
    url: "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
  },
];

const copyWasm = () => {
  // The package only exports its bundle entry (not package.json), so resolve the
  // entry and take the wasm/ dir beside it.
  const pkgRoot = dirname(require.resolve("@mediapipe/tasks-vision"));
  const wasmSrc = join(pkgRoot, "wasm");
  const wasmDest = join(publicDir, "wasm");
  cpSync(wasmSrc, wasmDest, { recursive: true });
  log(`wasm  → ${wasmDest}`);
};

const downloadModel = ({ name, url }) =>
  new Promise((resolve, reject) => {
    const modelsDir = join(publicDir, "models");
    const dest = join(modelsDir, name);
    if (existsSync(dest)) {
      log(`model → ${dest} (already present, skipped)`);
      resolve();
      return;
    }
    mkdirSync(modelsDir, { recursive: true });
    get(url, (res) => {
      if (res.statusCode !== 200) {
        reject(new Error(`model download failed (${name}): HTTP ${res.statusCode}`));
        res.resume();
        return;
      }
      const file = createWriteStream(dest);
      res.pipe(file);
      file.on("finish", () => file.close(() => resolve()));
      file.on("error", reject);
    }).on("error", reject);
    log(`model → ${dest} (downloading…)`);
  });

copyWasm();
Promise.all(MODELS.map(downloadModel))
  .then(() => log("done."))
  .catch((err) => {
    process.stderr.write(`${err.message}\n`);
    process.exitCode = 1;
  });
