import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { APP_NAME } from "@handsoff/contracts";

import { App } from "./App";
import "./index.css";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error(`${APP_NAME}: #root element not found`);
}

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
