import { Dashboard } from "./screens/dashboard/Dashboard";

// Shell entry. For issue #15 the app renders only the dashboard; routing
// (settings, etc.) lands with later surfaces.
export function App() {
  return <Dashboard />;
}
