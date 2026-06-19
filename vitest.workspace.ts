import { defineWorkspace } from "vitest/config";

// One project that collects every package's *.test.ts. Stays green before any
// tests exist; area owners add tests beside their source.
export default defineWorkspace([
  {
    test: {
      name: "unit",
      include: ["packages/**/*.test.ts"],
      exclude: ["**/node_modules/**", "**/dist/**"],
      passWithNoTests: true,
    },
  },
]);
