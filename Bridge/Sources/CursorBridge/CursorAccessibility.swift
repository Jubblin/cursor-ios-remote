import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum CursorAccessibility {
    static let approvalContextPhrases = [
        "waiting for approval",
        "requires approval",
        "needs approval",
        "needs your approval",
        "wants to run",
        "run this command",
        "shell command",
        "terminal command",
        "tool call",
        "allowlist",
        "allow list",
        "to proceed",
        "approve",
    ]

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func hasPendingApproval(in appElement: AXUIElement, labels: [String]) -> Bool {
        findApprovalButtonMatch(in: appElement, labels: labels) != nil
    }

    static func findApprovalButton(in appElement: AXUIElement, labels: [String]) -> AXUIElement? {
        findApprovalButtonMatch(in: appElement, labels: labels)?.element
    }

    static func findApprovalButtonMatch(
        in appElement: AXUIElement,
        labels: [String]
    ) -> (element: AXUIElement, label: String)? {
        var contextElements: [AXUIElement] = []
        findElementsWithApprovalContext(in: appElement, depth: 0, into: &contextElements)
        guard !contextElements.isEmpty else { return nil }

        for contextElement in contextElements {
            var current: AXUIElement? = contextElement
            for _ in 0 ..< 8 {
                guard let node = current else { break }
                for label in labels {
                    if let match = findClickable(titled: label, in: node, depth: 0, preferDeepest: true) {
                        return (match, label)
                    }
                }
                current = parent(of: node)
            }
        }
        return nil
    }

    static func focusApprovalRegion(in appElement: AXUIElement) -> Bool {
        var contextElements: [AXUIElement] = []
        findElementsWithApprovalContext(in: appElement, depth: 0, into: &contextElements)
        guard let target = contextElements.first else { return false }
        var current: AXUIElement? = target
        for _ in 0 ..< 4 {
            guard let node = current else { break }
            if clickAtCenter(of: node) { return true }
            current = parent(of: node)
        }
        return false
    }

    static func clickViaAppleScript(labels: [String]) -> (success: Bool, message: String?) {
        for label in labels {
            let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = """
            tell application "System Events"
                tell process "Cursor"
                    set frontmost to true
                    delay 0.15
                    repeat with w in windows
                        repeat with grp in UI elements of w
                            try
                                set grpName to (name of grp as text)
                                set grpDesc to ""
                                try
                                    set grpDesc to (description of grp as text)
                                end try
                                if grpName contains "approval" or grpDesc contains "approval" or grpName contains "command" or grpDesc contains "command" or grpName contains "terminal" or grpDesc contains "terminal" then
                                    try
                                        click (first button of grp whose name contains "\(escaped)")
                                        return
                                    end try
                                end if
                            end try
                        end repeat
                    end repeat
                    error "No contextual button matching \(escaped)"
                end tell
            end tell
            """
            let result = runAppleScript(script)
            if result.success {
                return (true, "Clicked \(label) in approval area")
            }
        }
        return (false, nil)
    }

    static func pressElement(_ element: AXUIElement) -> (success: Bool, error: String?) {
        if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
            return (true, nil)
        }
        if clickAtCenter(of: element) {
            return (true, nil)
        }
        return (false, "Could not press element")
    }

    static func runAppleScript(_ source: String) -> (success: Bool, error: String?) {
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

    private static func findElementsWithApprovalContext(
        in element: AXUIElement,
        depth: Int,
        into results: inout [AXUIElement]
    ) {
        if depth > 35 { return }

        let text = elementText(element)
        if approvalContextPhrases.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            results.append(element)
        }

        for child in children(of: element) {
            findElementsWithApprovalContext(in: child, depth: depth + 1, into: &results)
        }
    }

    private static func findClickable(
        titled title: String,
        in element: AXUIElement,
        depth: Int,
        preferDeepest: Bool = false
    ) -> AXUIElement? {
        if depth > 40 { return nil }

        if isPressable(element), elementMatchesLabel(element, title: title) {
            return element
        }

        if elementText(element).localizedCaseInsensitiveContains(title),
           let ancestor = pressableAncestor(of: element) {
            return ancestor
        }

        var bestMatch: AXUIElement?
        var bestDepth = preferDeepest ? -1 : Int.max
        for child in children(of: element) {
            if let found = findClickable(titled: title, in: child, depth: depth + 1, preferDeepest: preferDeepest) {
                let foundDepth = depth + 1
                if preferDeepest {
                    if foundDepth > bestDepth {
                        bestMatch = found
                        bestDepth = foundDepth
                    }
                } else if foundDepth < bestDepth {
                    bestMatch = found
                    bestDepth = foundDepth
                }
            }
        }
        return bestMatch
    }

    private static func isPressable(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else { return false }

        let pressableRoles = [
            kAXButtonRole as String,
            "AXLink",
            "AXPopUpButton",
            "AXMenuItem",
            "AXCheckBox",
        ]
        if pressableRoles.contains(role) { return true }

        var actions: CFArray?
        guard AXUIElementCopyActionNames(element, &actions) == .success,
              let names = actions as? [String] else { return false }
        return names.contains(kAXPressAction as String)
    }

    private static func pressableAncestor(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0 ..< 8 {
            guard let node = current else { return nil }
            if isPressable(node) { return node }
            current = parent(of: node)
        }
        return nil
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
              let parent = parentRef else { return nil }
        return unsafeBitCast(parent, to: AXUIElement.self)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return [] }
        return children
    }

    private static func elementText(_ element: AXUIElement) -> String {
        let attributes = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
            kAXHelpAttribute as String,
        ]
        for attribute in attributes {
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef) == .success,
                  let string = valueRef as? String,
                  !string.isEmpty else { continue }
            return string
        }
        return ""
    }

    private static func clickAtCenter(of element: AXUIElement) -> Bool {
        guard let center = elementCenter(element) else { return false }
        guard let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: center,
            mouseButton: .left
        ),
            let mouseUp = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: center,
                mouseButton: .left
            ) else {
            return false
        }

        mouseDown.post(tap: .cgSessionEventTap)
        mouseUp.post(tap: .cgSessionEventTap)
        return true
    }

    private static func elementCenter(_ element: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let point = cgPoint(from: posRef),
              let size = cgSize(from: sizeRef) else {
            return nil
        }
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    private static func cgPoint(from ref: CFTypeRef?) -> CGPoint? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        let axValue = unsafeBitCast(ref, to: AXValue.self)
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func cgSize(from ref: CFTypeRef?) -> CGSize? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        let axValue = unsafeBitCast(ref, to: AXValue.self)
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func elementMatchesLabel(_ element: AXUIElement, title: String) -> Bool {
        elementText(element).localizedCaseInsensitiveContains(title)
    }
}
