import AppKit
import ApplicationServices
import Foundation

final class CursorAutomation {
    private let approvalButtonLabels = [
        "Run", "Accept", "Approve", "Continue", "Allow", "Yes",
    ]
    private let rejectButtonLabels = [
        "Skip", "Reject", "Deny", "Cancel", "No",
    ]

    func isCursorRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cursor.Cursor").isEmpty
    }

    func detectSessionStatus() -> SessionStatus {
        guard isCursorRunning() else {
            return SessionStatus(
                state: .idle,
                detail: "Cursor is not running",
                cursorRunning: false
            )
        }

        guard let cursorApp = focusedCursorApp() else {
            return SessionStatus(
                state: .unknown,
                detail: "Cursor is running but not reachable",
                cursorRunning: true
            )
        }

        let appElement = AXUIElementCreateApplication(cursorApp.processIdentifier)
        if let approvalLabel = findApprovalButtonLabel(in: appElement) {
            return SessionStatus(
                state: .awaitingApproval,
                detail: "Waiting: \(approvalLabel)",
                cursorRunning: true
            )
        }

        if windowTitleIndicatesActivity(appElement) {
            return SessionStatus(
                state: .running,
                detail: "Agent appears active",
                cursorRunning: true
            )
        }

        return SessionStatus(
            state: .idle,
            detail: "No pending approval detected",
            cursorRunning: true
        )
    }

    func sendPrompt(_ text: String) -> ActionResponse {
        guard isCursorRunning() else {
            return ActionResponse(success: false, message: "Cursor is not running")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ActionResponse(success: false, message: "Prompt is empty")
        }

        activateCursor()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Open agent/composer: Cmd+I is common in Cursor for composer
        let openComposer = """
        tell application "System Events"
            keystroke "i" using {command down}
            delay 0.3
            keystroke "v" using {command down}
            delay 0.1
            keystroke return
        end tell
        """
        let result = runAppleScript(openComposer)
        if result.success {
            return ActionResponse(success: true, message: "Prompt sent to Cursor")
        }
        return ActionResponse(success: false, message: result.error ?? "Failed to send prompt")
    }

    func approve() -> ActionResponse {
        clickMatchingButton(labels: approvalButtonLabels, fallbackKey: returnKeyScript())
    }

    func reject() -> ActionResponse {
        clickMatchingButton(labels: rejectButtonLabels, fallbackKey: escapeKeyScript())
    }

    func selectConversation(workspacePath: String, conversationName: String) -> ActionResponse {
        openWorkspace(workspacePath)

        activateCursor()
        Thread.sleep(forTimeInterval: 2.0)

        // Open chat history via command palette
        let openHistory = """
        tell application "System Events"
            keystroke "p" using {command down, shift down}
            delay 0.5
            keystroke "Show Chat History"
            delay 0.3
            keystroke return
            delay 0.6
        end tell
        """
        var result = runAppleScript(openHistory)
        if !result.success {
            // Fallback command label used in some Cursor builds
            let fallback = """
            tell application "System Events"
                keystroke "p" using {command down, shift down}
                delay 0.5
                keystroke "Previous Chats"
                delay 0.3
                keystroke return
                delay 0.6
            end tell
            """
            result = runAppleScript(fallback)
        }
        guard result.success else {
            return ActionResponse(success: false, message: result.error ?? "Could not open chat history")
        }

        let searchTerm = String(conversationName.prefix(40))
            .replacingOccurrences(of: "\"", with: "'")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(searchTerm, forType: .string)

        let searchAndOpen = """
        tell application "System Events"
            keystroke "f" using {command down}
            delay 0.2
            keystroke "v" using {command down}
            delay 0.3
            keystroke return
            delay 0.2
            keystroke return
        end tell
        """
        result = runAppleScript(searchAndOpen)
        if result.success {
            return ActionResponse(success: true, message: "Opened conversation: \(conversationName)")
        }
        return ActionResponse(success: false, message: result.error ?? "Could not select conversation")
    }

    // MARK: - Private

    private func openWorkspace(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Cursor", path]
        try? process.run()
        process.waitUntilExit()
    }

    private func focusedCursorApp() -> NSRunningApplication? {
        let ids = ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app
            }
        }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == "Cursor" }
    }

    private func activateCursor() {
        _ = runAppleScript("""
        tell application "Cursor" to activate
        delay 0.2
        """)
    }

    private func findApprovalButtonLabel(in appElement: AXUIElement) -> String? {
        for label in approvalButtonLabels {
            if findButton(titled: label, in: appElement) != nil {
                return label
            }
        }
        return nil
    }

    private func windowTitleIndicatesActivity(_ appElement: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String,
               title.localizedCaseInsensitiveContains("agent")
                || title.localizedCaseInsensitiveContains("composer")
                || title.localizedCaseInsensitiveContains("chat") {
                return true
            }
        }
        return false
    }

    private func clickMatchingButton(labels: [String], fallbackKey: String) -> ActionResponse {
        guard isCursorRunning() else {
            return ActionResponse(success: false, message: "Cursor is not running")
        }
        activateCursor()

        guard let app = focusedCursorApp() else {
            return ActionResponse(success: false, message: "Could not find Cursor process")
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        for label in labels {
            if let button = findButton(titled: label, in: appElement) {
                let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
                if err == .success {
                    return ActionResponse(success: true, message: "Clicked \(label)")
                }
            }
        }

        let fallback = runAppleScript(fallbackKey)
        if fallback.success {
            return ActionResponse(success: true, message: "Used keyboard fallback")
        }
        return ActionResponse(success: false, message: fallback.error ?? "No matching control found")
    }

    private func findButton(titled title: String, in element: AXUIElement) -> AXUIElement? {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return nil }

        if role == kAXButtonRole as String {
            var titleValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
               let buttonTitle = titleValue as? String,
               buttonTitle.localizedCaseInsensitiveContains(title) {
                return element
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return nil }

        for child in children {
            if let found = findButton(titled: title, in: child) {
                return found
            }
        }
        return nil
    }

    private func returnKeyScript() -> String {
        """
        tell application "System Events"
            keystroke return
        end tell
        """
    }

    private func escapeKeyScript() -> String {
        """
        tell application "System Events"
            key code 53
        end tell
        """
    }

    private func runAppleScript(_ source: String) -> (success: Bool, error: String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return (false, "Invalid AppleScript")
        }
        script.executeAndReturnError(&error)
        if let error {
            return (false, error[NSAppleScript.errorMessage] as? String)
        }
        return (true, nil)
    }
}
