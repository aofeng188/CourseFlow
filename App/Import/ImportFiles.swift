import Foundation
import UIKit
import PDFKit
import CoreXLSX
import CourseKit

struct ImportSourceAsset: Codable, Identifiable, Sendable {
    var id = UUID()
    var label: String
    var imageFile: String
    var originalFile: String
    var extractedText: String = ""
    var embeddedText: String = ""
    var embeddedTables: [[ImportTableCell]] = []
    var recognizedPeriods: [Period] = []
    var pageNumber: Int
}

struct ImportWorkspace: Codable, Sendable {
    var semesterID: UUID?
    var draft: ImportDraft
    var assets: [ImportSourceAsset] = []
    var textSources: [String] = []
    /// Optional so workspaces saved before AI text import continue to decode.
    var aiPasteText: String? = nil
}

enum ImportDraftStorage {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ImportDrafts", isDirectory: true)
    }
    static func file(_ name: String) -> URL { directory.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent) }
    static func load(semesterID: UUID?, kind: ImportKind = .timetable) -> ImportWorkspace? {
        let name = "draft-\(semesterID?.uuidString ?? "none")-\(kind.rawValue).json"
        return (try? Data(contentsOf: file(name))).flatMap { try? JSONDecoder().decode(ImportWorkspace.self, from: $0) }
    }
    static func save(_ workspace: ImportWorkspace) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "draft-\(workspace.semesterID?.uuidString ?? "none")-\(workspace.draft.kind.rawValue).json"
        try JSONEncoder().encode(workspace).write(to: file(name), options: [.atomic, .completeFileProtection])
    }
    static func saveImage(_ data: Data) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        try data.write(to: file(name), options: [.atomic, .completeFileProtection])
        return name
    }
    static func clear(_ workspace: ImportWorkspace) {
        try? FileManager.default.removeItem(at: file("draft-\(workspace.semesterID?.uuidString ?? "none")-\(workspace.draft.kind.rawValue).json"))
        for asset in workspace.assets {
            try? FileManager.default.removeItem(at: file(asset.imageFile))
            if asset.originalFile != asset.imageFile { try? FileManager.default.removeItem(at: file(asset.originalFile)) }
        }
    }
    static func clearAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    static func copyInput(_ url: URL) throws -> URL {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 40_000_000 else { throw ImportServiceError.message("文件超过 40 MB，请压缩图片或分成多个文件导入。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = file(UUID().uuidString + "." + url.pathExtension)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

struct ImportPDFPage: Identifiable, Sendable {
    var number: Int
    var thumbnail: Data
    var id: Int { number }
}

struct ImportSheet: Identifiable, Sendable {
    var id: String
    var name: String
    var rows: [[String]]
    var cells: [ImportTableCell]
}

actor ImportFileReader {
    func pdfPages(at url: URL) throws -> [ImportPDFPage] {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw ImportServiceError.message("无法打开此 PDF。若文件加密，请先解锁并另存一份。") }
        guard document.pageCount <= 300 else { throw ImportServiceError.message("PDF 页数过多，请先导出需要的课表页。") }
        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index), let data = page.thumbnail(of: CGSize(width: 180, height: 240), for: .mediaBox).jpegData(compressionQuality: 0.7) else { return nil }
            return ImportPDFPage(number: index + 1, thumbnail: data)
        }
    }
    func pdfImage(at url: URL, pageNumber: Int) throws -> (Data, RecognizedImportPage) {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageNumber - 1) else { throw ImportServiceError.message("无法读取 PDF 的第 \(pageNumber) 页。") }
        let rect = page.bounds(for: .mediaBox)
        let scale = min(2.5, 2500 / max(rect.width, rect.height))
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let data = image.jpegData(compressionQuality: 0.92) else { throw ImportServiceError.message("无法渲染 PDF 页面。") }
        return (data, nativePDFText(page))
    }
    func readText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let chinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let encodings: [String.Encoding] = hasUTF16BOM ? [.utf16, .utf8, chinese] : [.utf8, chinese]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw ImportServiceError.message("无法识别文件编码，请将表格另存为 UTF-8 CSV 后导入。")
    }
    func workbook(at url: URL) throws -> [ImportSheet] {
        guard let file = XLSXFile(filepath: url.path) else { throw ImportServiceError.message("无法打开 Excel。支持未加密的 .xlsx；旧版 .xls 请另存为 .xlsx 或 CSV。") }
        let strings = try file.parseSharedStrings()
        var output: [ImportSheet] = []
        for workbook in try file.parseWorkbooks() {
            for (name, path) in try file.parseWorksheetPathsAndNames(workbook: workbook) {
                let sheet = try file.parseWorksheet(at: path)
                let rawCells = (sheet.data?.rows ?? []).flatMap(\.cells)
                guard rawCells.count <= 50_000 else { throw ImportServiceError.message("工作表内容过多，请复制需要的课表区域到新文件后导入。") }
                var cells: [ImportTableCell] = []
                for cell in rawCells {
                    let coordinates = Self.coordinate(cell.reference.description)
                    guard coordinates.row < 2000, coordinates.column < 150 else { continue }
                    let value = strings.flatMap { cell.stringValue($0) } ?? cell.inlineString?.text ?? cell.value ?? ""
                    guard !value.isEmpty else { continue }
                    cells.append(ImportTableCell(text: value, row: coordinates.row, column: coordinates.column))
                }
                for merge in sheet.mergeCells?.items ?? [] {
                    let range = merge.reference.split(separator: ":").map(String.init)
                    guard range.count == 2 else { continue }
                    let start = Self.coordinate(range[0]), end = Self.coordinate(range[1])
                    if let index = cells.firstIndex(where: { $0.row == start.row && $0.column == start.column }) {
                        cells[index].rowSpan = max(1, end.row - start.row + 1)
                        cells[index].columnSpan = max(1, end.column - start.column + 1)
                    }
                }
                let height = min(2000, (cells.map(\.row).max() ?? -1) + 1)
                let width = min(150, (cells.map(\.column).max() ?? -1) + 1)
                var rows = Array(repeating: Array(repeating: "", count: width), count: height)
                for cell in cells { rows[cell.row][cell.column] = cell.text }
                output.append(ImportSheet(id: path, name: name ?? "工作表 \(output.count + 1)", rows: rows, cells: cells))
            }
        }
        guard !output.isEmpty else { throw ImportServiceError.message("Excel 中没有可读取的工作表。") }
        return output
    }
    private static func coordinate(_ value: String) -> (row: Int, column: Int) {
        let letters = value.uppercased().filter(\.isLetter)
        var column = 0
        for scalar in letters.unicodeScalars { column = column * 26 + Int(scalar.value) - 64 }
        return (max(0, (Int(value.filter(\.isNumber)) ?? 1) - 1), max(0, column - 1))
    }

    private struct PDFRun { var text: String; var bounds: CGRect }
    /// PDFKit reads the text layer first. Coordinate reconstruction is deliberately
    /// conservative; images and ambiguous layouts fall back to Vision later.
    private func nativePDFText(_ page: PDFPage) -> RecognizedImportPage {
        let text = page.string ?? ""
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { return RecognizedImportPage(text: "", tables: []) }
        let lines = pdfTextRuns(page, text: text)
        if let cells = nativePDFList(lines) {
            return RecognizedImportPage(text: text, tables: [cells], warning: "已优先读取 PDF 原生列表文字和坐标，请核对课程对应关系。")
        }
        var headers = lines.filter { ImportParser.weekday($0.text) != nil && Int($0.text) == nil }
        headers.sort { $0.bounds.midX < $1.bounds.midX }
        guard headers.count >= 3, headers.count <= 7,
              Set(headers.compactMap { ImportParser.weekday($0.text) }).count == headers.count,
              let left = headers.first?.bounds.minX, let headingY = headers.first?.bounds.midY else {
            return RecognizedImportPage(text: text, tables: [])
        }
        let anchors = lines.filter { line in
            line.bounds.midX < left && line.bounds.midY < headingY && line.text.range(of: #"^(?:第\s*)?[0-9一二三四五六七八九十]{1,3}(?:\s*[-–、,]\s*[0-9]{1,2})?\s*节?$"#, options: .regularExpression) != nil
        }.sorted { $0.bounds.midY > $1.bounds.midY }
        guard !anchors.isEmpty, anchors.count <= 30 else { return RecognizedImportPage(text: text, tables: []) }
        var cells = headers.enumerated().map { ImportTableCell(text: $0.element.text, row: 0, column: $0.offset + 1) }
        for (index, anchor) in anchors.enumerated() {
            cells.append(ImportTableCell(text: anchor.text, row: index + 1, column: 0))
            let top = index == 0 ? headingY : (anchors[index - 1].bounds.midY + anchor.bounds.midY) / 2
            let bottom = index == anchors.count - 1 ? -Double.greatestFiniteMagnitude : (anchors[index + 1].bounds.midY + anchor.bounds.midY) / 2
            for (column, header) in headers.enumerated() {
                let minX = column == 0 ? left - max(15, header.bounds.width) : (headers[column - 1].bounds.midX + header.bounds.midX) / 2
                let maxX = column == headers.count - 1 ? Double.greatestFiniteMagnitude : (headers[column + 1].bounds.midX + header.bounds.midX) / 2
                let runs = lines.filter { $0.bounds.midY < top && $0.bounds.midY >= bottom && $0.bounds.midX > minX && $0.bounds.midX < maxX && $0.bounds.midX >= left }
                guard runs.allSatisfy({ $0.bounds.minX >= minX - 10 && $0.bounds.maxX <= maxX + 10 }) else { return RecognizedImportPage(text: text, tables: []) }
                let content = runs.sorted { $0.bounds.midY > $1.bounds.midY }.map(\.text).joined(separator: "\n")
                if !content.isEmpty { cells.append(ImportTableCell(text: content, row: index + 1, column: column + 1)) }
            }
        }
        return RecognizedImportPage(text: text, tables: [cells], warning: "已优先读取 PDF 原生文字和坐标，请核对合并单元格与跨节课程。")
    }

    /// PDFKit may concatenate a visual row into one string. Character geometry
    /// keeps cells separate without depending on the PDF's whitespace ordering.
    private func pdfTextRuns(_ page: PDFPage, text: String) -> [PDFRun] {
        var runs: [PDFRun] = [], current = "", bounds = CGRect.null, previous: CGRect?
        for index in text.indices {
            let symbol = text[index]
            if symbol.isNewline {
                if let run = Self.finishedPDFRun(current, bounds: bounds) { runs.append(run) }
                current = ""; bounds = .null; previous = nil
                continue
            }
            if symbol.isWhitespace { current.append(symbol); continue }
            let range = index..<text.index(after: index)
            guard let selection = page.selection(for: NSRange(range, in: text)) else { continue }
            let character = selection.bounds(for: page)
            guard !character.isEmpty, !character.isInfinite, !character.isNull else { continue }
            if let previous {
                let height = max(previous.height, character.height)
                if character.minX - previous.maxX > height * 0.85 || abs(character.midY - previous.midY) > height * 0.5 || character.minX < previous.minX - 2 {
                    if let run = Self.finishedPDFRun(current, bounds: bounds) { runs.append(run) }
                    current = ""; bounds = .null
                }
            }
            current.append(symbol); bounds = bounds.union(character); previous = character
        }
        if let run = Self.finishedPDFRun(current, bounds: bounds) { runs.append(run) }
        return runs
    }

    private static func finishedPDFRun(_ text: String, bounds: CGRect) -> PDFRun? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !bounds.isNull else { return nil }
        return PDFRun(text: value, bounds: bounds)
    }

    private func nativePDFList(_ runs: [PDFRun]) -> [ImportTableCell]? {
        let namedHeaders = runs.filter { ImportParser.guessedMapping([$0.text]).first == .name }.sorted { $0.bounds.midY > $1.bounds.midY }
        for name in namedHeaders {
            let headers = runs.filter { abs($0.bounds.midY - name.bounds.midY) <= max($0.bounds.height, name.bounds.height) * 0.5 && ImportParser.guessedMapping([$0.text]).first != .ignore }.sorted { $0.bounds.midX < $1.bounds.midX }
            let mapping = ImportParser.guessedMapping(headers.map(\.text))
            guard headers.count >= 3, Set(mapping).count == mapping.count, mapping.contains(.weekday), mapping.contains(.periods) || (mapping.contains(.start) && mapping.contains(.end)) else { continue }
            let content = runs.filter { $0.bounds.midY < name.bounds.minY }.sorted { $0.bounds.midY > $1.bounds.midY }
            var rows: [[PDFRun]] = []
            for run in content {
                if let last = rows.last?.first, abs(last.bounds.midY - run.bounds.midY) <= max(last.bounds.height, run.bounds.height) * 0.5 { rows[rows.count - 1].append(run) }
                else { rows.append([run]) }
            }
            var cells = headers.enumerated().map { ImportTableCell(text: $0.element.text, row: 0, column: $0.offset) }
            for (rowIndex, row) in rows.enumerated() {
                for (column, header) in headers.enumerated() {
                    let minX = column == 0 ? -Double.greatestFiniteMagnitude : (headers[column - 1].bounds.midX + header.bounds.midX) / 2
                    let maxX = column == headers.count - 1 ? Double.greatestFiniteMagnitude : (headers[column + 1].bounds.midX + header.bounds.midX) / 2
                    let parts = row.filter { $0.bounds.midX >= minX && $0.bounds.midX < maxX }.sorted { $0.bounds.minX < $1.bounds.minX }
                    guard parts.allSatisfy({ $0.bounds.minX >= minX - 10 && $0.bounds.maxX <= maxX + 10 }) else { return nil }
                    let value = parts.map(\.text).joined(separator: " ")
                    if !value.isEmpty { cells.append(ImportTableCell(text: value, row: rowIndex + 1, column: column)) }
                }
            }
            if cells.count > headers.count { return cells }
        }
        return nil
    }
}

extension UIImage {
    func importNormalized(maxDimension: CGFloat = 3000) -> UIImage {
        let ratio = min(1, maxDimension / max(size.width, size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: target))
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
    func importRotated() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width), format: format).image { context in
            context.cgContext.translateBy(x: size.height, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
