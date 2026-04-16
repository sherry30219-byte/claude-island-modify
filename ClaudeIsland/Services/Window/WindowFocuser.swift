//
//  WindowFocuser.swift
//  ClaudeIsland
//
//  Focuses windows using yabai or native macOS APIs
//

import AppKit
import Foundation

/// Focuses windows using yabai or native macOS APIs
actor WindowFocuser {
    static let shared = WindowFocuser()

    private init() {}

    /// Focus a window by ID (yabai)
    func focusWindow(id: Int) async -> Bool {
        guard let yabaiPath = await WindowFinder.shared.getYabaiPath() else { return false }

        do {
            _ = try await ProcessExecutor.shared.run(yabaiPath, arguments: [
                "-m", "window", "--focus", String(id)
            ])
            return true
        } catch {
            return false
        }
    }

    /// Focus the tmux window for a terminal (yabai)
    func focusTmuxWindow(terminalPid: Int, windows: [YabaiWindow]) async -> Bool {
        // Try to find actual tmux window
        if let tmuxWindow = WindowFinder.shared.findTmuxWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: tmuxWindow.id)
        }

        // Fall back to any non-Claude window
        if let window = WindowFinder.shared.findNonClaudeWindow(forTerminalPid: terminalPid, windows: windows) {
            return await focusWindow(id: window.id)
        }

        return false
    }

    /// Focus the terminal app for a Claude session using native macOS APIs (no yabai needed)
    /// Uses Accessibility API to raise the specific window matching the project.
    func focusTerminalNatively(forClaudePid claudePid: Int, projectName: String? = nil, cwd: String? = nil) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        // For tmux sessions, switch to the correct pane first
        if ProcessTreeBuilder.shared.isInTmux(pid: claudePid, tree: tree) {
            if let target = await TmuxController.shared.findTmuxTarget(forClaudePid: claudePid) {
                _ = await TmuxController.shared.switchToPane(target: target)
            }
        }

        // Find the terminal/editor app
        let runningApps = NSWorkspace.shared.runningApplications
        var targetApp: NSRunningApplication?

        for app in runningApps {
            guard let bundleId = app.bundleIdentifier,
                  TerminalAppRegistry.isTerminalBundle(bundleId) else { continue }

            let appPid = Int(app.processIdentifier)
            if ProcessTreeBuilder.shared.isDescendant(targetPid: claudePid, ofAncestor: appPid, tree: tree) {
                targetApp = app
                break
            }
        }

        // Fallback: walk up process tree
        if targetApp == nil, let terminalPid = ProcessTreeBuilder.shared.findTerminalPid(forProcess: claudePid, tree: tree) {
            targetApp = NSRunningApplication(processIdentifier: pid_t(terminalPid))
        }

        guard let app = targetApp else {
            print("[WindowFocuser] No target app found for claudePid: \(claudePid)")
            return false
        }

        // Build search terms
        let folderName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let searchTerms = [projectName, folderName].compactMap { $0?.lowercased() }

        print("[WindowFocuser] Focusing: app=\(app.localizedName ?? "?"), pid=\(claudePid), searchTerms=\(searchTerms), projectName=\(projectName ?? "nil"), cwd=\(cwd ?? "nil")")

        // Strategy A: Use AppleScript via System Events to raise the specific window
        if !searchTerms.isEmpty, let appName = app.localizedName {
            print("[WindowFocuser] Trying Strategy A (AppleScript)...")
            let raised = await raiseWindowViaAppleScript(appName: appName, searchTerms: searchTerms)
            if raised {
                print("[WindowFocuser] Strategy A succeeded")
                return true
            }
            print("[WindowFocuser] Strategy A failed")
        }

        // Strategy B: Use AX API as fallback
        print("[WindowFocuser] Trying Strategy B (AX API)...")
        let raised = raiseWindow(forApp: app, projectName: projectName, cwd: cwd)
        if raised {
            print("[WindowFocuser] Strategy B succeeded")
            activateApp(app)
            return true
        }
        print("[WindowFocuser] Strategy B failed")

        // Strategy C: Just activate the app
        print("[WindowFocuser] Falling back to Strategy C (activate app)")
        activateApp(app)
        return true
    }

    /// Focus the terminal for a session by working directory (fallback when no PID)
    func focusTerminalNatively(forWorkingDirectory cwd: String, projectName: String? = nil) async -> Bool {
        let tree = ProcessTreeBuilder.shared.buildTree()

        for (pid, info) in tree {
            guard info.command.lowercased().contains("claude") else { continue }
            guard let processCwd = ProcessTreeBuilder.shared.getWorkingDirectory(forPid: pid),
                  processCwd == cwd else { continue }

            return await focusTerminalNatively(forClaudePid: pid, projectName: projectName, cwd: cwd)
        }

        return false
    }

    // MARK: - App Activation

    /// Activate an app reliably on macOS 14+.
    /// Uses NSWorkspace.openApplication which works even from a non-activating panel.
    private func activateApp(_ app: NSRunningApplication) {
        guard let bundleURL = app.bundleURL else {
            app.activate()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, error in
            if let error = error {
                print("[WindowFocuser] NSWorkspace.openApplication failed: \(error), falling back to activate()")
                app.activate()
            }
        }
    }

    // MARK: - AppleScript Window Raising

    /// Raise a specific window using AppleScript via System Events.
    /// This is the most reliable method for switching between windows in VS Code, Cursor, etc.
    private func raiseWindowViaAppleScript(appName: String, searchTerms: [String]) async -> Bool {
        // Build AppleScript that finds and raises the window matching our search terms
        // We check each window's name against all search terms
        let conditions = searchTerms.map { term in
            "name of w contains \"\(term)\""
        }.joined(separator: " or ")

        let script = """
        tell application "System Events"
            tell process "\(appName)"
                set frontmost to true
                repeat with w in windows
                    if \(conditions) then
                        perform action "AXRaise" of w
                        return true
                    end if
                end repeat
            end tell
        end tell
        return false
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var error: NSDictionary?
                let result = appleScript?.executeAndReturnError(&error)
                if let error = error {
                    print("[WindowFocuser] AppleScript error: \(error)")
                }
                let success = result?.booleanValue ?? false
                print("[WindowFocuser] AppleScript result: \(success), appName: \(appName), searchTerms: \(searchTerms)")
                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Accessibility API Window Raising (Fallback)

    /// Raise a specific window of an app by matching the project name in the window title.
    /// Uses the Accessibility API (requires Accessibility permission).
    private nonisolated func raiseWindow(forApp app: NSRunningApplication, projectName: String?, cwd: String?) -> Bool {
        let appPid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(appPid)

        // Get the app's windows
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        guard result == .success, let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        // Build search terms from project name and cwd
        let folderName = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let searchTerms = [projectName, folderName].compactMap { $0?.lowercased() }

        guard !searchTerms.isEmpty else { return false }

        // Find the window whose title matches
        for window in windows {
            var titleRef: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard titleResult == .success, let title = titleRef as? String else { continue }

            let titleLower = title.lowercased()
            for term in searchTerms {
                if titleLower.contains(term) {
                    // Raise this window
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    return true
                }
            }
        }

        return false
    }
}
