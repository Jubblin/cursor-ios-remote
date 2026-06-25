import AppKit
import ApplicationServices
import Foundation

final class CursorAutomation {
    private let automationQueue = DispatchQueue(label: "cursor.bridge.automation", qos: .userInitiated)

    private let approvalButtonLabels = [
        "Run", "Accept", "Approve", "Allow once", "Always allow", "Allow", "Yes", "Execute", "Confirm",
    ]
    private let rejectButtonLabels = [
        "Skip", "Reject", "Deny", "Cancel", "No", "Decline",
    ]

    private var lastDetectedApprovalLabel: String?

    func isCursorRunning() -> Bool {
        runOnAutomationQueue {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").isEmpty
                || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cursor.Cursor").isEmpty
        }
    }

    func detectSessionStatus() -> SessionStatus {
        runOnAutomationQueue {
            guard isCursorRunningOnMain() else {
                lastDetectedApprovalLabel = nil
                return SessionStatus(
                    state: .idle,
                    detail: "Cursor is not running",
                    cursorRunning: false
                )
            }

            guard let cursorApp = focusedCursorAppOnMain() else {
                lastDetectedApprovalLabel = nil
                return SessionStatus(
                    state: .unknown,
                    detail: "Cursor is running but not reachable",
                    cursorRunning: true
                )
            }

            let appElement = AXUIElementCreateApplication(cursorApp.processIdentifier)
            if let match = CursorAccessibility.findApprovalButtonMatch(
                in: appElement,
                labels: approvalButtonLabels
            ) {
                lastDetectedApprovalLabel = match.label
                return SessionStatus(
                    state: .awaitingApproval,
                    detail: "Waiting: \(match.label)",
                    cursorRunning: true
                )
            }

            lastDetectedApprovalLabel = nil

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
    }

    func sendPrompt(_ text: String) -> ActionResponse {
        runOnAutomationQueue {
            guard isCursorRunningOnMain() else {
                return ActionResponse(success: false, message: "Cursor is not running")
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ActionResponse(success: false, message: "Prompt is empty")
            }

            activateCursorOnMain()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

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
    }

    func approve() -> ActionResponse {
        runOnAutomationQueue {
            performApprovalAction(approve: true)
        }
    }

    func reject() -> ActionResponse {
        runOnAutomationQueue {
            performApprovalAction(approve: false)
        }
    }

    private func performApprovalAction(approve: Bool) -> ActionResponse {
        guard CursorAccessibility.isTrusted else {
            return ActionResponse(
                success: false,
                message: "Grant Accessibility permission to CursorBridge in System Settings → Privacy & Security → Accessibility"
            )
        }
        guard isCursorRunningOnMain() else {
            return ActionResponse(success: false, message: "Cursor is not running")
        }

        let pending = detectSessionStatus()
        guard pending.state == .awaitingApproval else {
            return ActionResponse(success: false, message: "No pending approval detected on Mac right now")
        }

        let labels = approve
            ? orderedApprovalLabels()
            : rejectButtonLabels

        activateCursorOnMain()
        Thread.sleep(forTimeInterval: 0.2)

        guard let app = focusedCursorAppOnMain() else {
            return ActionResponse(success: false, message: "Could not find Cursor process")
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var pressErrors: [String] = []

        let contextFocused = CursorAccessibility.focusApprovalRegion(in: appElement)
        let contextualButton = CursorAccessibility.findApprovalButton(in: appElement, labels: labels)
        print(
            "[Bridge] approve: pending=\(pending.detail ?? "unknown") "
                + "labels=\(labels.prefix(3).joined(separator: ",")) "
                + "contextFocused=\(contextFocused) buttonFound=\(contextualButton != nil)"
        )

        _ = contextFocused
        Thread.sleep(forTimeInterval: 0.15)

        if let appleScriptResult = tryAppleScriptClick(labels: labels, approve: approve) {
            Thread.sleep(forTimeInterval: 0.5)
            if approvalCleared() {
                return appleScriptResult
            }
            pressErrors.append("AppleScript click did not clear approval")
        }

        if let button = contextualButton {
            let press = CursorAccessibility.pressElement(button)
            if press.success {
                Thread.sleep(forTimeInterval: 0.5)
                if approvalCleared() {
                    return ActionResponse(success: true, message: "Clicked approval button in agent panel")
                }
                pressErrors.append("Clicked approval button but dialog still pending")
            } else if let reason = press.error {
                pressErrors.append(reason)
            }
        } else {
            pressErrors.append("No approval button found near agent prompt")
        }

        if approve, let shortcutResult = tryKeyboardApprovalShortcuts(appElement: appElement, pressErrors: &pressErrors) {
            return shortcutResult
        } else if !approve, let rejectResult = tryKeyboardReject(appElement: appElement, pressErrors: &pressErrors) {
            return rejectResult
        }

        if pressErrors.isEmpty {
            return ActionResponse(success: false, message: "Could not find approval controls in Cursor agent panel")
        }
        return ActionResponse(success: false, message: pressErrors.joined(separator: "; "))
    }

    private func tryKeyboardApprovalShortcuts(
        appElement: AXUIElement,
        pressErrors: inout [String]
    ) -> ActionResponse? {
        let shortcuts: [(String, String)] = [
            ("Tab+Enter", """
            tell application "System Events"
                tell process "Cursor"
                    set frontmost to true
                    keystroke tab
                    delay 0.1
                    keystroke return
                end tell
            end tell
            """),
            ("Enter", """
            tell application "System Events"
                tell process "Cursor"
                    set frontmost to true
                    keystroke return
                end tell
            end tell
            """),
            ("Cmd+Enter", """
            tell application "System Events"
                tell process "Cursor"
                    set frontmost to true
                    keystroke return using {command down}
                end tell
            end tell
            """),
        ]
        for (name, script) in shortcuts {
            _ = CursorAccessibility.focusApprovalRegion(in: appElement)
            if CursorAccessibility.runAppleScript(script).success {
                Thread.sleep(forTimeInterval: 0.5)
                if approvalCleared() {
                    return ActionResponse(success: true, message: "Used \(name) shortcut")
                }
                pressErrors.append("\(name) did not clear approval")
            }
        }
        return nil
    }

    private func tryKeyboardReject(appElement: AXUIElement, pressErrors: inout [String]) -> ActionResponse? {
        _ = CursorAccessibility.focusApprovalRegion(in: appElement)
        let fallbackResult = CursorAccessibility.runAppleScript(escapeKeyScript())
        if fallbackResult.success {
            Thread.sleep(forTimeInterval: 0.5)
            if approvalCleared() {
                return ActionResponse(success: true, message: "Used Escape key")
            }
            pressErrors.append("Escape key did not clear approval")
        } else if let error = fallbackResult.error {
            pressErrors.append(error)
        }
        return nil
    }

    private func orderedApprovalLabels() -> [String] {
        let preferred = lastDetectedApprovalLabel.map { [$0] } ?? []
        return preferred + approvalButtonLabels.filter { !preferred.contains($0) }
    }

    private func tryAppleScriptClick(labels: [String], approve: Bool) -> ActionResponse? {
        let result = CursorAccessibility.clickViaAppleScript(labels: labels)
        if result.success {
            return ActionResponse(success: true, message: result.message ?? (approve ? "Approved" : "Rejected"))
        }
        return nil
    }

    private func approvalCleared() -> Bool {
        detectSessionStatus().state != .awaitingApproval
    }

    func selectConversation(workspacePath: String, conversationName: String) -> ActionResponse {
        runOnAutomationQueue {
            openWorkspace(workspacePath)

            activateCursorOnMain()
            Thread.sleep(forTimeInterval: 2.0)

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
    }

    // MARK: - Private

    private func runOnAutomationQueue<T>(_ block: () -> T) -> T {
        automationQueue.sync(execute: block)
    }

    private func isCursorRunningOnMain() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.todesktop.230313mzl4w4u92").isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: "com.cursor.Cursor").isEmpty
    }

    private func openWorkspace(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Cursor", path]
        try? process.run()
        process.waitUntilExit()
    }

    private func focusedCursorAppOnMain() -> NSRunningApplication? {
        let ids = ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                return app
            }
        }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == "Cursor" }
    }

    private func activateCursorOnMain() {
        _ = CursorAccessibility.runAppleScript("""
        tell application "Cursor" to activate
        delay 0.2
        """)
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
