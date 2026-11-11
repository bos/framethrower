import AppKit
import SwiftUI

@main @MainActor
struct DirectorMarkdownChecks {
    enum Failure: Error { case failed(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.failed(message) }
    }
    static func main() throws {
        let source = """
        ## What I can see

        The **browser window** contains *settings* and `File > Open`.

        1. Zoom into [the browser](https://example.com).
        2. Pan to the sidebar.
           - Keep a 30 pixel border.

        > The original recording stays unchanged.

        ```swift
        let framing = "browser"
        ```

        | Target | Time |
        | --- | ---: |
        | Browser | 2 s |
        | Sidebar | 5 s |
        """
        let blocks = DirectorMarkdown.blocks(source)
        try require(blocks.first?.kind == .heading(2) && String(blocks[0].text.characters) == "What I can see", "Heading markers should render as native heading structure")
        try require(blocks.flatMap { $0.text.runs }.contains { $0[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]?.contains(.stronglyEmphasized) == true }, "Bold styling lost")
        try require(blocks.flatMap { $0.text.runs }.contains { $0[AttributeScopes.FoundationAttributes.LinkAttribute.self]?.absoluteString == "https://example.com" }, "Explicit links lost")
        try require(blocks.compactMap(\.marker) == ["1.", "2.", "•"], "Ordered and nested bullet list structure lost")
        try require(blocks.contains { $0.indent == 1 && $0.marker == "•" }, "Nested list indentation lost")
        try require(blocks.contains { $0.quoteDepth == 1 }, "Quote structure lost")
        try require(blocks.contains { $0.kind == .code && String($0.text.characters).contains("let framing") }, "Code fence should become code, not raw fence markup")
        let table = blocks.first { $0.kind == .table }
        try require(table?.tableRows.count == 3 && table?.tableRows[1].map { String($0.characters) } == ["Browser", "2 s"] && table?.columnAlignment.last == .right, "Table rows, cells or alignment lost")
        let multi = DirectorMarkdown.blocks("- First **bold** item\n\n  Continuation paragraph.\n- Second item")
        try require(multi.compactMap(\.marker) == ["•", "•"] && multi[1].isList && multi[1].marker == nil, "A continuation paragraph must retain list alignment without duplicating its bullet")
        let quotedTable = DirectorMarkdown.blocks("> | A | B |\n> | --- | --- |\n> | One | Two |")
        try require(quotedTable.first?.kind == .table && quotedTable.first?.quoteDepth == 1, "A quoted table must remain inside its quotation")
        let listTable = DirectorMarkdown.blocks("- Outer\n  - Inner\n\n    | A | B |\n    | --- | --- |\n    | One | Two |")
        try require(listTable.last?.kind == .table && listTable.last?.indent == 1 && listTable.last?.isList == true && listTable.last?.marker == nil,
            "A table continued inside a nested list must retain its indentation and list gutter")
        let literal = DirectorMarkdown.blocks("Use **unfinished text")
        try require(literal.count == 1 && String(literal[0].text.characters) == "Use **unfinished text", "Incomplete Markdown must remain readable")
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: DirectorMarkdownView(source).font(.callout).padding(16).frame(width: 330).background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(x: 0, y: 0, width: 330, height: 680)
        host.layoutSubtreeIfNeeded()
        try require(host.fittingSize.width <= 331 && host.fittingSize.height > 200, "Reply layout must wrap within the narrow inspector")
        if let argument = CommandLine.arguments.dropFirst().first,
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: argument)) }
        }
        print("Director Markdown checks passed: headings, inline styles/links, nested lists, continuation paragraphs, quotes, code, tables and narrow native layout; no network or media.")
    }
}
