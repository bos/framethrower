import Foundation
import SwiftUI

/// Foundation's CommonMark parser supplies structure and inline attributes.
/// Rendering stays native: model replies cannot execute HTML or load images.
struct DirectorMarkdownBlock: Identifiable {
    enum Kind: Equatable { case paragraph, heading(Int), code, rule, table }
    let id: Int
    var kind: Kind
    var text: AttributedString
    var indent = 0
    var quoteDepth = 0
    var marker: String?
    var isList = false
    var tableRows: [[AttributedString]] = []
    var columnAlignment: [PresentationIntent.TableColumn.Alignment] = []
}

enum DirectorMarkdown {
    static func blocks(_ source: String) -> [DirectorMarkdownBlock] {
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else {
            return [.init(id: 0, kind: .paragraph, text: AttributedString(source))]
        }
        var result: [DirectorMarkdownBlock] = []
        var seenItems: Set<Int> = []
        var rowIDs: [Int: Int] = [:]
        for run in parsed.runs {
            let components = run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]?.components ?? []
            var text = AttributedString(parsed[run.range])
            text[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self] = nil
            if let table = components.first(where: { if case .table = $0.kind { return true }; return false }),
               case let .table(columns) = table.kind,
               let row = components.first(where: { if case .tableHeaderRow = $0.kind { return true }; if case .tableRow = $0.kind { return true }; return false }),
               let cell = components.first(where: { if case .tableCell = $0.kind { return true }; return false }),
               case let .tableCell(column) = cell.kind {
                if result.last?.id != table.identity {
                    let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
                    let item = components.first { if case .listItem = $0.kind { return true }; return false }
                    var marker: String?
                    if let item, case let .listItem(ordinal) = item.kind, seenItems.insert(item.identity).inserted {
                        marker = lists.first?.kind == .orderedList ? "\(ordinal)." : "•"
                    }
                    result.append(.init(id: table.identity, kind: .table, text: AttributedString(),
                        indent: max(0, lists.count - 1), quoteDepth: components.filter { $0.kind == .blockQuote }.count,
                        marker: marker, isList: !lists.isEmpty, columnAlignment: columns.map(\.alignment)))
                }
                let index = result.count - 1
                if rowIDs[row.identity] == nil {
                    rowIDs[row.identity] = result[index].tableRows.count
                    result[index].tableRows.append(Array(repeating: AttributedString(), count: columns.count))
                }
                if let r = rowIDs[row.identity], column < columns.count {
                    result[index].tableRows[r][column].append(text)
                }
                continue
            }
            let identity = components.first?.identity ?? 0
            if result.last?.id == identity { result[result.count - 1].text.append(text); continue }
            let kind: DirectorMarkdownBlock.Kind
            switch components.first?.kind {
            case let .header(level): kind = .heading(level)
            case .codeBlock: kind = .code
            case .thematicBreak: kind = .rule
            default: kind = .paragraph
            }
            let lists = components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
            let item = components.first { if case .listItem = $0.kind { return true }; return false }
            var marker: String?
            if let item, case let .listItem(ordinal) = item.kind, seenItems.insert(item.identity).inserted {
                marker = lists.first?.kind == .orderedList ? "\(ordinal)." : "•"
            }
            result.append(.init(id: identity, kind: kind, text: text, indent: max(0, lists.count - 1),
                quoteDepth: components.filter { $0.kind == .blockQuote }.count, marker: marker, isList: !lists.isEmpty))
        }
        return result.isEmpty ? [.init(id: 0, kind: .paragraph, text: AttributedString(source))] : result
    }
}

struct DirectorMarkdownView: View {
    private let blocks: [DirectorMarkdownBlock]
    init(_ source: String) { blocks = DirectorMarkdown.blocks(source) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                HStack(alignment: .top, spacing: 7) {
                    if block.quoteDepth > 0 { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                    if block.isList { Text(block.marker ?? "").frame(minWidth: 14, alignment: .trailing) }
                    content(block)
                }
                .padding(.leading, CGFloat(block.indent * 16))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    @ViewBuilder private func content(_ block: DirectorMarkdownBlock) -> some View {
        switch block.kind {
        case .rule: Divider()
        case .heading(let level):
            Text(styled(block.text)).font(level == 1 ? .headline : .subheadline).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: true)
                    .padding(7)
            }
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(block.tableRows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                Text(styled(cell)).fontWeight(row == 0 ? .semibold : .regular)
                                    .gridColumnAlignment(alignment(block.columnAlignment[column]))
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(.vertical, 3)
            }
        case .paragraph: Text(styled(block.text))
        }
    }
    private func styled(_ value: AttributedString) -> AttributedString {
        var value = value
        for run in value.runs where run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self]?.contains(.code) == true {
            value[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(.callout, design: .monospaced)
            value[run.range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = .primary.opacity(0.055)
        }
        return value
    }
    private func alignment(_ value: PresentationIntent.TableColumn.Alignment) -> HorizontalAlignment {
        switch value { case .center: .center; case .right: .trailing; default: .leading }
    }
}
