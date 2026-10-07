import AppKit

// Deterministic, fictional source documents for testing the on-device importer.
@MainActor final class SampleView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat = 24, bold: Bool = false) {
            (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                .foregroundColor: NSColor.black
            ])
        }
        text("课序 · 导入测试样本", x: 50, y: 40, size: 36, bold: true)
        text("以下均为虚构课程。包含直接时间，无需预设学校作息。", x: 50, y: 100, size: 20)
        let rows = [
            "高等数学 周一 08:00-09:40 1-8周 地点:明德楼A301 教师:陈老师",
            "大学英语 周三 10:00-11:40 1-16周(单) 地点:博学楼B205 教师:李老师",
            "程序设计 周四 14:00-15:40 2,4,6,8周 地点:计算机中心302 教师:张老师",
            "艺术鉴赏 周五 19:00-20:30 9-16周 地点:综合楼101 教师:王老师"
        ]
        for (index, row) in rows.enumerated() {
            let y = 180 + CGFloat(index) * 95
            NSColor(white: 0.94, alpha: 1).setFill()
            NSRect(x: 35, y: y - 12, width: 1130, height: 68).fill()
            text(row, x: 50, y: y)
        }
        text("导入后请核对：星期、时间、周次、地点和教师。", x: 50, y: 620, size: 22)
        text("学校作息测试：", x: 50, y: 705, bold: true)
        text("第1节 08:00-08:45    第2节 08:55-09:40", x: 50, y: 755)
        text("第3节 10:00-10:45    第4节 10:55-11:40", x: 50, y: 810)
    }
}

try MainActor.assumeIsolated {
    let view = SampleView(frame: NSRect(x: 0, y: 0, width: 1200, height: 920))
    let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try view.dataWithPDF(inside: view.bounds).write(to: directory.appendingPathComponent("示例课程与作息.pdf"))
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("示例课程与作息.png"))
    }
}
