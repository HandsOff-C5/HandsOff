//
//  AppContextCatalogTests.swift
//  DirectorSidecarTests
//
//  Unit coverage for plan U11's per-app context catalog (Intent/AppContextCatalog.swift). The
//  catalog is pure data over pure functions — no I/O, no driver, no AX — so these tests drive
//  `match` and `contextFragment` directly with literal app names. No mocks, no fixtures.
//

import Testing
import Foundation
@testable import DirectorSidecar

// MARK: - Known apps render their key affordances

@Test
func fragmentForBrowserCarriesFindInPageAndAddressBar() {
    let fragment = AppContextCatalog.contextFragment(for: "Google Chrome")
    #expect(fragment != nil)
    // The browser entry's load-bearing affordances: find-in-page and the address bar chord.
    #expect(fragment?.contains("Cmd+F") == true)
    #expect(fragment?.contains("Cmd+L") == true)
}

@Test
func fragmentForBraveResolvesViaTheBrowserFamily() {
    // Brave shares the Chromium entry — the same fragment, headed by the family display name.
    let fragment = AppContextCatalog.contextFragment(for: "Brave Browser")
    #expect(fragment != nil)
    #expect(fragment?.contains("Cmd+L") == true)
}

@Test
func fragmentForTerminalWarnsThatPasteDoesNotAutoRun() {
    let fragment = AppContextCatalog.contextFragment(for: "Terminal")
    #expect(fragment != nil)
    // The Terminal/iTerm2 entry's key trap: a paste does not press Enter for you.
    #expect(fragment?.contains("does NOT auto-run") == true)
}

@Test
func fragmentForIterm2ResolvesViaTheTerminalFamily() {
    let fragment = AppContextCatalog.contextFragment(for: "iTerm2")
    #expect(fragment != nil)
    #expect(fragment?.contains("Return") == true)
}

@Test
func fragmentForChessDescribesTheTwoClickAxBlindMove() {
    let fragment = AppContextCatalog.contextFragment(for: "Chess")
    #expect(fragment != nil)
    // Chess's board is custom-drawn / AX-blind; the move is source-square then destination-square.
    #expect(fragment?.contains("AX-blind") == true)
    #expect(fragment?.contains("destination square") == true)
}

@Test
func fragmentForTextEditCoversNewDocAndPlainText() {
    let fragment = AppContextCatalog.contextFragment(for: "TextEdit")
    #expect(fragment != nil)
    #expect(fragment?.contains("Cmd+N") == true)
    #expect(fragment?.contains("Make Plain Text") == true)
}

@Test
func fragmentForNotesCoversNewNote() {
    let fragment = AppContextCatalog.contextFragment(for: "Notes")
    #expect(fragment != nil)
    #expect(fragment?.contains("Cmd+N") == true)
}

// MARK: - Guardrail is always present

@Test
func renderedFragmentIncludesTheSilentUseGuardrail() {
    let fragment = AppContextCatalog.contextFragment(for: "Notes")
    #expect(fragment?.contains(AppContextCatalog.guardrail) == true)
    // The guardrail must instruct silent use — never announcing the playbook to the user.
    #expect(AppContextCatalog.guardrail.contains("silently") == true)
    #expect(AppContextCatalog.guardrail.lowercased().contains("never announce") == true)
}

// MARK: - Unknown apps are nil-safe

@Test
func fragmentForUnknownAppIsNil() {
    #expect(AppContextCatalog.contextFragment(for: "Adobe Photoshop") == nil)
    #expect(AppContextCatalog.match(appName: "Adobe Photoshop") == nil)
}

@Test
func lookupIsNilSafeForNilAndBlankNames() {
    #expect(AppContextCatalog.match(appName: nil) == nil)
    #expect(AppContextCatalog.contextFragment(for: nil) == nil)
    #expect(AppContextCatalog.match(appName: "") == nil)
    #expect(AppContextCatalog.match(appName: "   ") == nil)
}

// MARK: - Matching is case / whitespace insensitive and bundle-id aware

@Test
func matchIsCaseInsensitive() {
    #expect(AppContextCatalog.match(appName: "google chrome") != nil)
    #expect(AppContextCatalog.match(appName: "TERMINAL") != nil)
}

@Test
func matchIsWhitespaceInsensitive() {
    // Leading/trailing padding and collapsed internal runs both resolve.
    #expect(AppContextCatalog.match(appName: "  Google Chrome  ") != nil)
    #expect(AppContextCatalog.match(appName: "google   chrome") != nil)
}

@Test
func matchIgnoresTrailingDotApp() {
    // "Chess.app" resolves to the same entry as "Chess".
    let viaSuffix = AppContextCatalog.match(appName: "Chess.app")
    let viaName = AppContextCatalog.match(appName: "Chess")
    #expect(viaSuffix != nil)
    #expect(viaSuffix == viaName)
}

@Test
func matchResolvesBundleIdentifiers() {
    #expect(AppContextCatalog.match(appName: "com.apple.Terminal") != nil)
    #expect(AppContextCatalog.match(appName: "com.apple.Notes") != nil)
}
