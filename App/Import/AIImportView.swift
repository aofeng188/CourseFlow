import SwiftUI
import UIKit
import CourseKit

struct AIImportView: View {
    let model: ImportFlowModel
    @State private var text: String
    @State private var copied = false
    @State private var error: String?
    @State private var showError = false
    @State private var isParsing = false
    @State private var submitted = false
    @State private var parsingTask: Task<Void, Never>?
    @FocusState private var editingText: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: ImportFlowModel) {
        self.model = model
        _text = State(initialValue: model.workspace.aiPasteText ?? "")
    }

    private var prompt: String {
        AIImportFormat.prompt(kind: model.workspace.draft.kind, maxWeeks: model.maxWeeks)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("让你常用的 AI 帮忙看图", systemImage: "sparkles").font(.headline)
                    Text("把提示词和图片发给支持看图的 AI，复制它生成的内容回来即可。无需在课序中配置 API Key。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("1 · 复制提示词") {
                    LabeledContent("识别内容", value: model.workspace.draft.kind == .timetable ? "课程表" : "学校作息表")
                    Button {
                        UIPasteboard.general.string = prompt
                        copied = true
                    } label: {
                        Label(copied ? "已复制提示词" : "复制提示词", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.accessibilityIdentifier("ai-import-copy-prompt")
                    ShareLink(item: prompt) { Label("分享提示词", systemImage: "square.and.arrow.up") }
                    DisclosureGroup("查看完整提示词") {
                        Text(prompt).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("2 · 发给其他 AI") {
                    Text("在其他 AI 的对话中粘贴提示词，并附上清晰的课表图片。多张图片可以一起发送；同格中的不同课程、不同周次和教室会分别整理。")
                        .font(.subheadline)
                    Text(model.workspace.draft.kind == .timetable
                         ? "只有第几节、没有具体时间也可以。回到课序后关联已确认的学校作息；作息图片可切换“学校作息表”后单独处理。"
                         : "请发送学校官方作息表图片。缺少或看不清的起止时间需先补全，不会自动生成猜测的时间。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("图片由你在所选 AI 中发送；此入口只在本机解析粘贴内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 240)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($editingText)
                        .accessibilityLabel("AI 生成的课程数据")
                        .accessibilityIdentifier("ai-import-text")
                    PasteButton(payloadType: String.self) { values in
                        text = values.joined(separator: "\n")
                    }.accessibilityIdentifier("ai-import-paste")
                } header: { Text("3 · 粘贴 AI 生成的内容") }
                footer: { Text("可直接粘贴 JSON 或带代码框的完整回复。点击右上角“核对内容”后，仍可逐条修改；确认前不会写入正式课表。未完成的粘贴内容会自动保留。") }

                if let error {
                    Section("需要调整") {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("ai-import-error")
                        Text("粘贴内容和已有草稿都已保留。可修改后重试，或把上面的提示发给 AI，让它重新生成完整数据。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(isParsing)
            .navigationTitle("AI 文本导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { parsingTask?.cancel(); persistInput(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("核对内容", action: parse)
                        .disabled(isParsing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ai-import-review")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isParsing {
                    HStack { ProgressView(); Text("正在整理待核对内容…").font(.subheadline) }
                        .frame(maxWidth: .infinity).padding().background(.regularMaterial)
                }
            }
            .task(id: text) {
                do { try await Task.sleep(for: .milliseconds(350)); persistInput() }
                catch { }
            }
            .alert("请调整 AI 返回内容", isPresented: $showError) {
                Button("复制错误提示") { UIPasteboard.general.string = error }
                Button("继续编辑", role: .cancel) { }
            } message: { Text(error ?? "请检查粘贴的内容。") }
            .onDisappear { parsingTask?.cancel(); persistInput() }
            .interactiveDismissDisabled(isParsing)
        }
    }

    private func persistInput() {
        guard !submitted else { return }
        model.workspace.aiPasteText = text.isEmpty ? nil : text
        model.save()
    }

    private func parse() {
        guard !isParsing else { return }
        editingText = false
        isParsing = true; error = nil
        parsingTask = Task {
            defer { isParsing = false; parsingTask = nil }
            do {
                try await model.importAIText(text)
                submitted = true
                dismiss()
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription; showError = true }
        }
    }
}
