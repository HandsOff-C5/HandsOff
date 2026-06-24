import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { APP_NAME } from "@handsoff/contracts";

import { App } from "./App";
import "./index.css";

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error(`${APP_NAME}: #root element not found`);
}

// Keep the webview title tracking the product name; index.html ships a static
// <title> only as the pre-hydration placeholder.
document.title = APP_NAME;

createRoot(rootElement).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
