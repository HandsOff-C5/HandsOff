import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: [
      "**/dist/**",
      "**/node_modules/**",
      "**/*.gitkeep",
      "apps/**/src-tauri/**",
      // Self-hosted MediaPipe assets (generated, gitignored) — not our source.
      "apps/**/public/wasm/**",
      "apps/**/public/models/**",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
);
