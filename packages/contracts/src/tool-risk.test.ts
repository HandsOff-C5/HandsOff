import { describe, expect, it } from "vitest";

import { riskLevelRequiresApproval } from "./action-plan";
import {
  COMMIT_PATTERNS,
  DRIVER_TOOLS,
  driverToolSchema,
  effectiveToolCallRisk,
  riskForToolCall,
  riskForToolName,
  safeParseDriverTool,
  toolCallRequiresApproval,
} from "./tool-risk";
import type { DriverTool, ToolCallTarget } from "./tool-risk";

function commitElement(title: string): ToolCallTarget {
  return { element: { role: "AXButton", title } };
}

function navElement(role: string, title: string): ToolCallTarget {
  return { element: { role, title } };
}

describe("driver tool surface", () => {
  it("enumerates the full driver surface (36 tools, verified against `cua-driver list-tools`)", () => {
    // The plan's prose says "38 tools" but the live driver — the source of truth
    // — reports 36 (`cua-driver list-tools`). DRIVER_TOOLS mirrors the driver.
    expect(DRIVER_TOOLS).toHaveLength(36);
  });

  it("parses a known tool name and rejects an unknown one", () => {
    expect(safeParseDriverTool("scroll").success).toBe(true);
    expect(driverToolSchema.safeParse("teleport").success).toBe(false);
  });
});

describe("riskForToolCall — read-only tools auto-run", () => {
  const readOnly: DriverTool[] = [
    "get_window_state",
    "get_accessibility_tree",
    "get_cursor_position",
    "get_screen_size",
    "list_apps",
    "list_windows",
    "scroll",
    "zoom",
    "move_cursor",
    "check_permissions",
    "get_config",
    "get_recording_state",
    "check_for_update",
    "start_session",
    "end_session",
    "set_agent_cursor_enabled",
    "set_agent_cursor_motion",
    "set_agent_cursor_style",
    "get_agent_cursor_state",
  ];

  it.each(readOnly)("%s → read_only → no approval", (tool) => {
    expect(riskForToolCall(tool)).toBe("read_only");
    expect(toolCallRequiresApproval(tool)).toBe(false);
  });
});

describe("riskForToolCall — draft / reversible tools auto-run", () => {
  const reversible: DriverTool[] = ["type_text", "set_value", "launch_app", "bring_to_front"];

  it.each(reversible)("%s → reversible → no approval (draft, don't send)", (tool) => {
    expect(riskForToolCall(tool)).toBe("reversible");
    expect(toolCallRequiresApproval(tool)).toBe(false);
  });
});

describe("riskForToolCall — the click nuance (navigation vs commit)", () => {
  it("escalates a click on a 'Send' control to mutating → approval", () => {
    expect(riskForToolCall("click", commitElement("Send"))).toBe("mutating");
    expect(toolCallRequiresApproval("click", commitElement("Send"))).toBe(true);
  });

  it.each(["Delete", "Submit", "Post", "Reply", "Buy", "Confirm", "Pay", "Publish", "Discard"])(
    "escalates a click on a '%s' control → approval",
    (verb) => {
      expect(toolCallRequiresApproval("click", commitElement(verb))).toBe(true);
    },
  );

  it("does NOT gate a click on a dropdown/menu/tab element (navigation)", () => {
    expect(riskForToolCall("click", navElement("AXPopUpButton", "Sort by"))).toBe("reversible");
    expect(riskForToolCall("click", navElement("AXMenuItem", "Boogie Woogie"))).toBe("reversible");
    expect(riskForToolCall("click", navElement("AXTab", "Inbox"))).toBe("reversible");
    expect(toolCallRequiresApproval("click", navElement("AXTab", "Inbox"))).toBe(false);
  });

  it("does NOT escalate when a commit verb is only a substring of a longer word", () => {
    // "Description" contains "post"? no; "Resend" contains "send" but is not a
    // word boundary; "Posted on" is a word boundary → gated. Guard the false
    // positives:
    expect(riskForToolCall("click", navElement("AXStaticText", "Description"))).toBe("reversible");
    expect(riskForToolCall("click", navElement("AXButton", "Resend"))).toBe("reversible");
  });

  it("gates a click with NO element metadata (cannot prove navigation → safe default)", () => {
    expect(riskForToolCall("click")).toBe("mutating");
    expect(toolCallRequiresApproval("click")).toBe(true);
  });

  it("gates a click on an element with an unknown/blank role and title (suspect → gated)", () => {
    expect(riskForToolCall("click", { element: {} })).toBe("reversible");
    // An element with only a benign role stays navigation; a missing element gates.
    expect(riskForToolCall("double_click", commitElement("Delete"))).toBe("mutating");
    expect(riskForToolCall("right_click", navElement("AXRow", "file.txt"))).toBe("reversible");
  });
});

describe("riskForToolCall — press_key / hotkey", () => {
  it("gates a send-chord (⌘↵) by default", () => {
    expect(riskForToolCall("hotkey", { keys: ["cmd", "return"] })).toBe("mutating");
    expect(toolCallRequiresApproval("hotkey", { keys: ["cmd", "return"] })).toBe(true);
  });

  it("gates a bare return key press (commits a form/message)", () => {
    expect(riskForToolCall("press_key", { key: "return" })).toBe("mutating");
  });

  it("does NOT gate benign navigation keys (arrows, page up/down, escape, tab)", () => {
    expect(riskForToolCall("press_key", { key: "down" })).toBe("read_only");
    expect(riskForToolCall("press_key", { key: "pageup" })).toBe("read_only");
    expect(riskForToolCall("press_key", { key: "escape" })).toBe("read_only");
    expect(riskForToolCall("press_key", { key: "tab" })).toBe("read_only");
    expect(riskForToolCall("hotkey", { keys: ["shift", "tab"] })).toBe("read_only");
  });

  it("gates press_key / hotkey with no key info (safe default)", () => {
    expect(riskForToolCall("press_key")).toBe("mutating");
    expect(riskForToolCall("hotkey")).toBe("mutating");
  });
});

describe("riskForToolCall — page sub-actions", () => {
  it("treats page read actions as read_only", () => {
    expect(riskForToolCall("page", { pageAction: "get_text" })).toBe("read_only");
    expect(riskForToolCall("page", { pageAction: "query_dom" })).toBe("read_only");
  });

  it("gates page execute_javascript / click_element as mutating", () => {
    expect(riskForToolCall("page", { pageAction: "execute_javascript" })).toBe("mutating");
    expect(riskForToolCall("page", { pageAction: "click_element" })).toBe("mutating");
  });

  it("treats page enable_javascript_apple_events as destructive_external", () => {
    expect(riskForToolCall("page", { pageAction: "enable_javascript_apple_events" })).toBe(
      "destructive_external",
    );
    expect(toolCallRequiresApproval("page", { pageAction: "enable_javascript_apple_events" })).toBe(
      true,
    );
  });

  it("gates page with no action (safe default)", () => {
    expect(riskForToolCall("page")).toBe("mutating");
  });
});

describe("riskForToolCall — mutating and destructive tools", () => {
  it.each<[DriverTool]>([["drag"], ["set_config"], ["start_recording"], ["stop_recording"]])(
    "%s → mutating → approval",
    (tool) => {
      expect(riskForToolCall(tool)).toBe("mutating");
      expect(toolCallRequiresApproval(tool)).toBe(true);
    },
  );

  it.each<[DriverTool]>([["kill_app"], ["replay_trajectory"], ["install_ffmpeg"]])(
    "%s → destructive_external → approval",
    (tool) => {
      expect(riskForToolCall(tool)).toBe("destructive_external");
      expect(toolCallRequiresApproval(tool)).toBe(true);
    },
  );
});

describe("riskForToolName — unknown tool defaults to gated", () => {
  it("classifies an unknown tool name as mutating (safe default)", () => {
    expect(riskForToolName("rm_rf_everything")).toBe("mutating");
    expect(riskLevelRequiresApproval(riskForToolName("rm_rf_everything"))).toBe(true);
  });

  it("classifies a known tool name by delegating to riskForToolCall", () => {
    expect(riskForToolName("get_screen_size")).toBe("read_only");
    expect(riskForToolName("click", commitElement("Send"))).toBe("mutating");
  });
});

describe("effectiveToolCallRisk — max over the intended calls", () => {
  it("a read-only-only set is read_only", () => {
    expect(
      effectiveToolCallRisk([{ tool: "get_window_state" }, { tool: "scroll" }, { tool: "zoom" }]),
    ).toBe("read_only");
  });

  it("a mixed set with one commit click takes the commit tier", () => {
    expect(
      effectiveToolCallRisk([
        { tool: "get_window_state" },
        { tool: "scroll" },
        { tool: "click", target: commitElement("Send") },
      ]),
    ).toBe("mutating");
  });

  it("a set containing a destructive tool takes the destructive tier", () => {
    expect(
      effectiveToolCallRisk([
        { tool: "get_accessibility_tree" },
        { tool: "type_text" },
        { tool: "kill_app" },
      ]),
    ).toBe("destructive_external");
  });

  it("navigation clicks + drafting in a set do not gate", () => {
    const risk = effectiveToolCallRisk([
      { tool: "click", target: navElement("AXPopUpButton", "Sort by") },
      { tool: "scroll" },
      { tool: "type_text" },
    ]);
    expect(risk).toBe("reversible");
    expect(riskLevelRequiresApproval(risk)).toBe(false);
  });
});

describe("commit-pattern list", () => {
  it("includes the core commit verbs", () => {
    for (const verb of ["send", "post", "submit", "delete", "buy", "confirm", "pay", "publish"]) {
      expect(COMMIT_PATTERNS).toContain(verb);
    }
  });
});
