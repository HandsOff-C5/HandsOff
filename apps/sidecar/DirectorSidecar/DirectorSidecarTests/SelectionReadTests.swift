//
//  SelectionReadTests.swift
//  DirectorSidecarTests
//
//  Unit coverage for the plan U9 selection-read capability (Intent/SelectionRead.swift). The AX
//  focused-element read and the live NSPasteboard read both require a real UI surface, so these
//  tests drive the two side-effect-free cores instead:
//
//    • normalizedSelection — the ~1500-char cap and blank-line/whitespace shaping
//    • clipboardSelection  — the changeCount > baseline gating (never synthesize ⌘C)
//
//  No AX tree, no pasteboard, no mocks: the cores are pure functions over their inputs.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Cap

@Test
func normalizedSelectionCapsAtMaxLength() {
    let raw = String(repeating: "a", count: 2_000)
    let result = SelectionRead.normalizedSelection(raw)
    #expect(result?.count == SelectionRead.maxLength)
    #expect(SelectionRead.maxLength == 1_500)
}

@Test
func normalizedSelectionKeepsShortTextIntact() {
    let result = SelectionRead.normalizedSelection("acceptance criteria")
    #expect(result == "acceptance criteria")
}

@Test
func normalizedSelectionTrimsAndCollapsesBlankLines() {
    let result = SelectionRead.normalizedSelection("  line one\n\n\n\nline two  ")
    #expect(result == "line one\nline two")
}

@Test
func normalizedSelectionReturnsNilForEmptyOrWhitespace() {
    #expect(SelectionRead.normalizedSelection("") == nil)
    #expect(SelectionRead.normalizedSelection("   \n\t  ") == nil)
}

// MARK: - changeCount gating

@Test
func clipboardSelectionReturnsValueWhenChangeCountAdvanced() {
    let result = SelectionRead.clipboardSelection(changeCount: 6, baseline: 5, value: "issue body")
    #expect(result == "issue body")
}

@Test
func clipboardSelectionReturnsNilWhenChangeCountUnchanged() {
    // changeCount == baseline → the clipboard has not changed since listening began; reject it.
    #expect(SelectionRead.clipboardSelection(changeCount: 5, baseline: 5, value: "stale") == nil)
}

@Test
func clipboardSelectionReturnsNilWhenChangeCountRegressed() {
    #expect(SelectionRead.clipboardSelection(changeCount: 4, baseline: 5, value: "stale") == nil)
}

@Test
func clipboardSelectionReturnsNilWhenValueMissing() {
    #expect(SelectionRead.clipboardSelection(changeCount: 99, baseline: 5, value: nil) == nil)
}

@Test
func clipboardSelectionCapsAdvancedValue() {
    let raw = String(repeating: "b", count: 2_000)
    let result = SelectionRead.clipboardSelection(changeCount: 6, baseline: 5, value: raw)
    #expect(result?.count == SelectionRead.maxLength)
}

@Test
func clipboardSelectionRejectsBlankAdvancedValue() {
    // Advanced changeCount but only whitespace → nil, not an empty selection downstream.
    #expect(SelectionRead.clipboardSelection(changeCount: 6, baseline: 5, value: "   ") == nil)
}
