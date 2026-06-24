// Minimal typing for the Vite-injected env we read (the project sets `types: []`, so
// we declare only what we use instead of pulling in all of vite/client).
interface ImportMetaEnv {
  // Set to "calibrate" by `pnpm calibrate` to launch the eye-calibration screen.
  readonly VITE_HANDSOFF_MODE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
