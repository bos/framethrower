import AppKit
@testable import FrameThrower

/// Inspects only this test's views. Shared navigation avoids a native popup
/// that macOS may reposition onscreen even when its parent is offscreen.
@MainActor enum EditorUIProbe {
    enum Failure: Error { case failed(String) }
    static func elements(in host: NSView) -> [any NSAccessibilityProtocol] {
        var seen = Set<ObjectIdentifier>()
        var result: [any NSAccessibilityProtocol] = []
        func visit(_ value: Any) {
            guard let element = value as? any NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element as AnyObject)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] { visit(child) }
        }
        func visitView(_ view: NSView) {
            visit(view)
            for child in view.subviews { visitView(child) }
        }
        visitView(host)
        return result
    }
    static func propertyTarget(in host: NSView) throws -> NSControl {
        func controls(_ view: NSView) -> [NSControl] {
            ((view as? NSControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
        }
        // SwiftUI's native menu control is not NSPopUpButton. Its semantic AX
        // wrapper is omitted in invisible accessory windows, so inspect the
        // real control/frame here and review its visible title in vector PNGs.
        guard let value = controls(host).first(where: { String(describing: type(of: $0)).contains("PopupButton") }) else {
            throw Failure.failed("Native property-target menu missing")
        }
        return value
    }
    static func context(editor: ProjectEditor) async throws -> [String: Any] {
        let data = try await EditorAutomationRegistry.shared.call("list_recordings", arguments: Data("{}".utf8))
        guard let list = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordings = list["recordings"] as? [[String: Any]],
              let recording = recordings.first(where: { ($0["recordingID"] as? String)?.lowercased() == editor.automationID.uuidString.lowercased() }) else { throw Failure.failed("Production editor navigation endpoint missing") }
        return recording
    }
    static func selectInspector(_ name: String, editor: ProjectEditor) async throws {
        guard let document = try await context(editor: editor)["documentID"] as? String else { throw Failure.failed("Document scope missing") }
        let result = try await EditorAutomationRegistry.shared.call("navigate_editor", arguments: JSONSerialization.data(withJSONObject: [
            "document_id": document, "operation": "show_inspector", "inspector": name
        ]))
        guard let response = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let state = response["result"] as? [String: Any], state["inspector"] as? String == name else {
            throw Failure.failed("Property target did not change to \(name)")
        }
    }
    static func checkSliderWidths(in host: NSView) throws {
        // Invisible accessory windows omit some synthetic SwiftUI AX nodes.
        // This covers exposed native sliders only; property-track usability
        // also requires reviewing the generated vector images.
        for element in elements(in: host) where element.accessibilityRole() == .slider {
            let frame = element.accessibilityFrame()
            guard frame.width == 0 || frame.width >= 60 else {
                throw Failure.failed("Unusable slider track \(element.accessibilityLabel() ?? "") is only \(frame.width) points wide")
            }
        }
    }
}
