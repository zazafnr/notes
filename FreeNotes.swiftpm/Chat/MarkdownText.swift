import SwiftUI

/// Kleiner Markdown-Renderer: Überschriften, Listen, Code und Fett/Kursiv.
struct MarkdownText: View {
    let text: String

    private enum Block {
        case heading(String, Int)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
        case divider
        case table([[String]])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let s, let level):
            inline(s)
                .font(level <= 1 ? .title3.weight(.bold) : .headline)
                .padding(.top, 4)
        case .bullet(let s):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").fontWeight(.bold)
                inline(s)
            }
        case .numbered(let n, let s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).fontWeight(.semibold).monospacedDigit()
                inline(s)
            }
        case .code(let s):
            Text(s)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        case .paragraph(let s):
            inline(s)
        case .divider:
            Divider()
        case .table(let rows):
            tableView(rows)
        }
    }

    /// Markdown-Tabelle als Raster; erste Zeile fett als Kopf.
    private func tableView(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            inline(c < row.count ? row[c] : "")
                                .fontWeight(r == 0 ? .semibold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(r == 0 ? Color.primary.opacity(0.07) : (r % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear))
                                .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        }
    }

    /// Zerlegt »| a | b |« in Zellen.
    private static func cells(_ line: String) -> [String] {
        var inner = line.trimmed
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.components(separatedBy: "|").map { $0.trimmed }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-:".contains($0) } }
    }

    private func inline(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: s, options: options) {
            return Text(attributed)
        }
        return Text(s)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]?
        let cleaned = LatexLite.clean(text)
        var table: [[String]] = []
        func flushTable() {
            if !table.isEmpty { result.append(.table(table)) }
            table = []
        }
        for rawLine in cleaned.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if code == nil, line.hasPrefix("|") {
                let row = Self.cells(line)
                if !Self.isSeparatorRow(row) { table.append(row) }
                continue
            }
            flushTable()
            if line.hasPrefix("```") {
                if let c = code {
                    result.append(.code(c.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(rawLine)
                continue
            }
            if line.isEmpty { continue }
            if line == "---" || line == "***" {
                result.append(.divider)
            } else if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                result.append(.heading(String(line.dropFirst(level)).trimmed, level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else if let range = line.range(of: #"^\d+[.)]\s"#, options: .regularExpression) {
                let number = String(line[range]).trimmed
                result.append(.numbered(number, String(line[range.upperBound...])))
            } else {
                result.append(.paragraph(line))
            }
        }
        flushTable()
        if let c = code { result.append(.code(c.joined(separator: "\n"))) }
        return result
    }
}
