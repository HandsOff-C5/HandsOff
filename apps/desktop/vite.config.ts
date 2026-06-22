/// <reference types="vitest/config" />
import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

// Vite + Vitest config for the HandsOff Tauri frontend.
// The dev server port is pinned to 1420 to match `src-tauri/tauri.conf.json`
// `build.devUrl`; a mismatch yields a blank window, so `strictPort` fails loud.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    // MediaPipe's wasm runtime wants cross-origin isolation (SharedArrayBuffer).
    // Tauri sets these for the bundled app via tauri.conf.json; mirror them in dev.
    headers: {
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: true,
  },
  test: {
    name: "desktop",
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.test.tsx"],
    setupFiles: ["./vitest-setup.ts"],
  },
});
