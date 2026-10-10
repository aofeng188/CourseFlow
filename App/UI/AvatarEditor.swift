import SwiftUI
import PhotosUI
import ImageIO
import CourseKit

/// Form rows for a course's avatar: its initial, custom text or an emoji, an icon, or a photo.
struct CourseAvatarChoices: View {
    private enum Mode: Hashable { case initial, text, symbol, photo }
    @Binding var course: Course
    @State private var mode: Mode
    // Each mode keeps its own draft, so trying another one does not lose the previous choice.
    @State private var text: String
    @State private var symbol: String
    @State private var image: Data?
    @State private var picked: PhotosPickerItem?
    @State private var photoError: String?

    init(course: Binding<Course>) {
        _course = course
        let style = course.wrappedValue.avatar
        _mode = State(initialValue: style?.image != nil ? .photo : (style?.symbol != nil ? .symbol : ((style?.text ?? "").isEmpty ? .initial : .text)))
        _text = State(initialValue: style?.text ?? "")
        _symbol = State(initialValue: style?.symbol ?? CourseAvatarSymbols.all[0])
        _image = State(initialValue: style?.image)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("课程头像").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 14) {
                CourseAvatar(course: course, size: 52)
                Picker("头像样式", selection: $mode) {
                    Text("首字").tag(Mode.initial); Text("文字").tag(Mode.text); Text("图标").tag(Mode.symbol); Text("照片").tag(Mode.photo)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("avatar-mode")
            }
        }
        .padding(.vertical, 3)
        .onChange(of: mode) { apply() }
        switch mode {
        case .initial: EmptyView()
        case .text:
            TextField("一两个字或表情，例如 \(String(course.name.prefix(2)).isEmpty ? "高数" : String(course.name.prefix(2)))", text: $text)
                .accessibilityIdentifier("avatar-text")
                .onChange(of: text) { apply() }
        case .symbol:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 8)], spacing: 8) {
                ForEach(CourseAvatarSymbols.all, id: \.self) { name in
                    Button { symbol = name; apply() } label: {
                        Image(systemName: name).font(.system(size: 17, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40)
                            .foregroundStyle(symbol == name ? Color.white : Color.primary)
                            .background(symbol == name ? AnyShapeStyle(Palette.solid(course.colorIndex).gradient) : AnyShapeStyle(Color.secondary.opacity(0.09)), in: .rect(cornerRadius: 10, style: .continuous))
                    }.buttonStyle(.plain).accessibilityLabel("图标 \(name)").accessibilityAddTraits(symbol == name ? .isSelected : [])
                }
            }.padding(.vertical, 4)
        case .photo:
            let title = image == nil ? "从相册选择照片" : "更换照片"
            PhotosPicker(selection: $picked, matching: .images) { Label(title, systemImage: "photo") }
                .onChange(of: picked) { _, item in
                    guard let item else { return }
                    Task {
                        // The picker runs out of process, so no photo library permission is needed.
                        if let data = try? await item.loadTransferable(type: Data.self), let avatar = CourseAvatarImage.make(from: data) {
                            image = avatar; photoError = nil; apply()
                        } else { photoError = "无法读取这张照片，请换一张试试。" }
                        picked = nil
                    }
                }
            if let photoError { Text(photoError).font(.caption).foregroundStyle(.red) }
            else if image == nil { Text("照片会裁成正方形并缩小保存；未选择时仍显示课程名首字。").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func apply() {
        switch mode {
        case .initial: course.avatar = nil
        case .text:
            // Only the first characters are used; the field itself is left alone so that
            // pinyin and other composing input is not cut off mid-word.
            let shown = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(CourseAvatarStyle.maxTextLength))
            course.avatar = shown.isEmpty ? nil : CourseAvatarStyle(text: shown)
        case .symbol: course.avatar = CourseAvatarStyle(symbol: symbol)
        case .photo: course.avatar = image.map { CourseAvatarStyle(image: $0) }
        }
    }
}

enum CourseAvatarSymbols {
    static let all: [String] = [
        "book.fill", "books.vertical.fill", "text.book.closed.fill", "character.book.closed.fill", "graduationcap.fill", "pencil.and.ruler.fill",
        "function", "sum", "x.squareroot", "percent", "chart.bar.fill", "chart.line.uptrend.xyaxis",
        "atom", "flask.fill", "testtube.2", "bolt.fill", "leaf.fill", "cross.case.fill", "stethoscope", "brain.head.profile",
        "globe.asia.australia.fill", "map.fill", "building.columns.fill", "scroll.fill", "textformat.abc", "quote.bubble.fill", "mic.fill",
        "laptopcomputer", "chevron.left.forwardslash.chevron.right", "cpu.fill", "network", "gearshape.2.fill", "wrench.and.screwdriver.fill", "hammer.fill",
        "paintpalette.fill", "paintbrush.pointed.fill", "camera.fill", "film.fill", "music.note", "theatermasks.fill",
        "figure.run", "sportscourt.fill", "basketball.fill", "soccerball", "heart.fill",
        "person.2.fill", "briefcase.fill", "banknote.fill", "scalemass.fill", "flag.fill", "lightbulb.fill", "puzzlepiece.fill", "star.fill"
    ].filter { UIImage(systemName: $0) != nil }
}

enum CourseAvatarImage {
    static let side: CGFloat = 192
    /// A center-cropped square JPEG, small enough to live inside the course record.
    static func make(from data: Data) -> Data? {
        // ImageIO decodes a reduced, correctly oriented copy without loading a full-size photo.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side * 3]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = CGFloat(thumbnail.width), height = CGFloat(thumbnail.height), short = min(width, height)
        guard short > 0, let square = thumbnail.cropping(to: CGRect(x: (width - short) / 2, y: (height - short) / 2, width: short, height: short).integral) else { return nil }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            UIImage(cgImage: square).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return [0.82, 0.6, 0.4].lazy.compactMap { rendered.jpegData(compressionQuality: $0) }.first { $0.count <= CourseAvatarStyle.maxImageBytes }
    }
}
