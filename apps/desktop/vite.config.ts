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
