import SwiftUI
import VisionKit
import CourseKit

struct ImportDocumentScanner: UIViewControllerRepresentable {
    let onResult: (Result<[Data], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onResult: (Result<[Data], Error>) -> Void
        init(onResult: @escaping (Result<[Data], Error>) -> Void) { self.onResult = onResult }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let data = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).importNormalized().jpegData(compressionQuality: 0.92) }
            onResult(.success(data))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onResult(.success([])) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) { onResult(.failure(error)) }
    }
}

struct ImportSourcePreview: View {
    let asset: ImportSourceAsset
    @State private var original = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = UIImage(contentsOfFile: ImportDraftStorage.file(original ? asset.originalFile : asset.imageFile).path) {
                        ImportZoomableImage(image: image).frame(height: 460).clipShape(.rect(cornerRadius: 16))
                    }
                    if asset.originalFile != asset.imageFile { Toggle("查看裁剪前的原图", isOn: $original) }
                    if !asset.extractedText.isEmpty {
                        Text("识别原文").font(.headline)
                        Text(asset.extractedText).font(.callout).textSelection(.enabled)
                    }
                }.padding()
            }
            .navigationTitle(asset.label).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct ImportZoomableImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView(); scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false; scroll.showsHorizontalScrollIndicator = false
        let imageView = UIImageView(image: image); imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), imageView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor), imageView.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        return scroll
    }
    func updateUIView(_ uiView: UIScrollView, context: Context) { context.coordinator.imageView?.image = image }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

struct ImportCropView: View {
    @State var image: UIImage
    let onSave: (Data) -> Void
    @State private var left = 0.0
    @State private var right = 1.0
    @State private var top = 0.0
    @State private var bottom = 1.0
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                        .overlay {
                            GeometryReader { geometry in
                                Rectangle().fill(.black.opacity(0.25))
                                    .mask {
                                        Rectangle().overlay {
                                            Rectangle().frame(width: geometry.size.width * (right - left), height: geometry.size.height * (bottom - top))
                                                .position(x: geometry.size.width * (left + right) / 2, y: geometry.size.height * (top + bottom) / 2)
                                                .blendMode(.destinationOut)
                                        }.compositingGroup()
                                    }
                                Rectangle().stroke(.white, lineWidth: 2)
                                    .frame(width: geometry.size.width * (right - left), height: geometry.size.height * (bottom - top))
                                    .position(x: geometry.size.width * (left + right) / 2, y: geometry.size.height * (top + bottom) / 2)
                            }
                        }
                        .clipShape(.rect(cornerRadius: 12))
                    VStack(spacing: 12) {
                        cropSlider("左边界", value: $left, range: 0...max(0.01, right - 0.05))
                        cropSlider("右边界", value: $right, range: min(0.99, left + 0.05)...1)
                        cropSlider("上边界", value: $top, range: 0...max(0.01, bottom - 0.05))
                        cropSlider("下边界", value: $bottom, range: min(0.99, top + 0.05)...1)
                    }
                    HStack {
                        Button("旋转 90°", systemImage: "rotate.right") { image = image.importRotated(); reset() }
                        Spacer()
                        Button("重置范围", systemImage: "arrow.counterclockwise") { reset() }
                    }.buttonStyle(.bordered)
                    Text("保留星期表头和左侧节次列，有助于准确识别课程位置。原图会保留，裁剪后需要重新识别。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("裁剪与旋转").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        guard let cg = image.cgImage else { return }
                        let rect = CGRect(x: Double(cg.width) * left, y: Double(cg.height) * top, width: Double(cg.width) * (right - left), height: Double(cg.height) * (bottom - top)).integral
                        guard let crop = cg.cropping(to: rect), let data = UIImage(cgImage: crop).jpegData(compressionQuality: 0.94) else { return }
                        onSave(data); dismiss()
                    }
                }
            }
        }
    }
    private func reset() { left = 0; right = 1; top = 0; bottom = 1 }
    private func cropSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack { Text(title).font(.caption).frame(width: 54, alignment: .leading); Slider(value: value, in: range).accessibilityLabel(title) }
    }
}

struct ImportPDFSelectionView: View {
    let pages: [ImportPDFPage]
    let onSelect: (Set<Int>) -> Void
    @State private var selected: Set<Int> = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 20) {
                    ForEach(pages) { page in
                        Button {
                            if selected.contains(page.number) { selected.remove(page.number) }
                            else if selected.count < 20 { selected.insert(page.number) }
                        } label: {
                            VStack {
                                if let image = UIImage(data: page.thumbnail) { Image(uiImage: image).resizable().scaledToFit().frame(height: 170).clipShape(.rect(cornerRadius: 8)) }
                                Label("第 \(page.number) 页", systemImage: selected.contains(page.number) ? "checkmark.circle.fill" : "circle").font(.callout)
                            }.padding(8).background(selected.contains(page.number) ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: .rect(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }.padding()
            }
            .navigationTitle("选择 PDF 页面").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { Text("已选 \(selected.count) 页 · 每次最多 20 页，稍后可以继续添加。").font(.caption).padding().frame(maxWidth: .infinity).background(.regularMaterial) }
            .onAppear { if selected.isEmpty, let first = pages.first { selected = [first.number] } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("添加") { onSelect(selected); dismiss() }.disabled(selected.isEmpty) }
            }
        }
    }
}

struct ImportTableSelectionView: View {
    let sheets: [ImportSheet]
    let kind: ImportKind
    let maxWeeks: Int
    let onImport: (ImportDraft) -> Void
    @State private var selectedIndex = 0
    @State private var headerRow = 0
    @State private var grid = false
    @State private var mapping: [ImportColumn] = []
    @Environment(\.dismiss) private var dismiss
    private var selected: ImportSheet? { sheets.indices.contains(selectedIndex) ? sheets[selectedIndex] : nil }
    var body: some View {
        NavigationStack {
            Form {
                Section("工作表") {
                    Picker("选择工作表", selection: $selectedIndex) { ForEach(Array(sheets.enumerated()), id: \.offset) { index, sheet in Text(sheet.name).tag(index) } }
                    if kind == .timetable { Picker("排列方式", selection: $grid) { Text("每行一门课").tag(false); Text("星期 × 节次网格").tag(true) }.pickerStyle(.segmented) }
                }
                if let selected {
                    if kind == .timetable && !grid {
                        Section("对应字段") {
                            Stepper("表头在第 \(headerRow + 1) 行", value: $headerRow, in: 0...max(0, min(100, selected.rows.count - 1)))
                            if selected.rows.indices.contains(headerRow) {
                                ForEach(Array(selected.rows[headerRow].enumerated()), id: \.offset) { index, header in
                                    Picker(header.isEmpty ? "第\(index + 1)列" : header, selection: Binding(get: { mapping.indices.contains(index) ? mapping[index] : .ignore }, set: { value in if mapping.indices.contains(index) { mapping[index] = value } })) {
                                        ForEach(ImportColumn.allCases) { field in Text(field.title).tag(field) }
                                    }
                                }
                            }
                        }
                    }
                    Section("内容预览") {
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(selected.rows.prefix(12).enumerated()), id: \.offset) { index, row in
                                    HStack(alignment: .top, spacing: 0) {
                                        Text("\(index + 1)").frame(width: 28)
                                        ForEach(Array(row.prefix(16).enumerated()), id: \.offset) { _, text in
                                            Text(text.isEmpty ? "—" : text).lineLimit(5).frame(width: 120, alignment: .leading).padding(7).background(index == headerRow ? Color.accentColor.opacity(0.07) : Color.clear)
                                        }
                                    }.font(.caption).overlay(alignment: .bottom) { Divider() }
                                }
                            }
                        }
                        Text("显示前12行、前16列。确认后会解析所选工作表，再逐条核对；公式只读取文件里保存的值。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if grid {
                        Section { Text("使用星期列与左侧节次行确定位置，保留 Excel 合并单元格。原表缺失星期或节次时，识别后需要手动补齐。")
                            .font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("核对表格格式").navigationBarTitleDisplayMode(.inline)
            .onAppear { configure() }
            .onChange(of: selectedIndex) { _, _ in configure() }
            .onChange(of: headerRow) { _, value in if let selected, selected.rows.indices.contains(value) { mapping = ImportParser.guessedMapping(selected.rows[value]) } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("识别") {
                        guard let selected else { return }
                        let draft: ImportDraft
                        if kind == .bellSchedule { draft = ImportParser.table(selected.rows, kind: kind, sourceName: selected.name, maxWeeks: maxWeeks) }
                        else if grid { draft = ImportParser.grid(selected.cells, sourceName: selected.name, maxWeeks: maxWeeks) }
                        else { draft = ImportParser.table(selected.rows, mapping: mapping, headerRow: headerRow, sourceName: selected.name, maxWeeks: maxWeeks) }
                        onImport(draft); dismiss()
                    }.disabled(selected == nil || (kind == .timetable && !grid && !mapping.contains(.name)))
                }
            }
        }
    }
    private func configure() {
        guard let selected else { return }
        headerRow = selected.rows.prefix(20).firstIndex { ImportParser.guessedMapping($0).contains(.name) } ?? 0
        mapping = selected.rows.indices.contains(headerRow) ? ImportParser.guessedMapping(selected.rows[headerRow]) : []
        grid = !mapping.contains(.name)
    }
}
