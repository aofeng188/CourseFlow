import SwiftUI
import UIKit
import CourseKit

struct CalendarSettingsView: View {
    let semester: Semester
    let occurrences: [Occurrence]
    var defaultLeadMinutes: Int = 10
    let onChange: (Set<String>, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview = CalendarSyncPreview()
    @State private var report: CalendarSyncReport?
    @State private var isBusy = false
    @State private var showRemoveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("\(semester.name)", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    Text("将每次上课时间与地点加入独立课表日历。日历中的提醒可覆盖整个学期。")
                        .foregroundStyle(.secondary)
                }
                if CalendarSyncService.shared.isOwnedByAnotherDevice(semester) {
                    Section {
                        Label("另一台设备正在管理此学期的日历", systemImage: "iphone.and.arrow.forward")
                        Text("请在那台设备同步，或先返回设置明确接管。课表仍可在这台设备查看和编辑。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if !preview.hasFullAccess {
                    Section {
                        Button("允许日历访问", systemImage: "calendar.badge.checkmark") {
                            Task { await authorize() }
                        }
                        Button("打开系统设置", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    } footer: {
                        Text("需要完整日历访问，以识别重复课程、更新调课和撤销导出。课序只管理自己添加的课程。")
                    }
                } else {
                    Section {
                        LabeledContent("新增", value: "\(preview.createCount) 次课程")
                        LabeledContent("更新", value: "\(preview.updateCount) 次课程")
                        LabeledContent("不变", value: "\(preview.unchangedCount) 次课程")
                        if preview.removeCount > 0 { LabeledContent("移除已停课程", value: "\(preview.removeCount) 次课程") }
                        if let name = preview.calendarName { LabeledContent("目标日历", value: name) }
                        Button {
                            Task { await synchronize() }
                        } label: {
                            HStack {
                                Label("同步到系统日历", systemImage: "arrow.triangle.2.circlepath")
                                Spacer()
                                if isBusy { ProgressView() }
                            }
                        }
                        .disabled(isBusy || !preview.errors.isEmpty)
                    } header: {
                        Text("同步预览")
                    } footer: {
                        Text("同一课次重复同步不会重复添加。课表更改后再次同步即可更新；您在系统日历中手改的内容会被保留。")
                    }
                }
                if !preview.errors.isEmpty {
                    Section("需要处理") {
                        ForEach(Array(preview.errors.enumerated()), id: \.offset) { _, error in
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                }
                if let report {
                    Section("最近结果") {
                        if report.errors.isEmpty {
                            Label("已核对 \(report.managedCount) 次课程", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        ForEach(Array(report.errors.enumerated()), id: \.offset) { _, error in
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
                let conflicts = report?.conflicts ?? preview.conflicts
                if !conflicts.isEmpty {
                    Section("已保留的日历改动") {
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                            Label(conflict, systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline)
                        }
                    }
                }
                if preview.hasFullAccess && !CalendarSyncService.shared.isOwnedByAnotherDevice(semester) {
                    Section {
                        Button("移除本学期已导出的课程", role: .destructive) { showRemoveConfirmation = true }
                            .disabled(isBusy)
                    } footer: {
                        Text("仅移除课序创建且未被手动改动的事件。独立日历会保留，其他日历不受影响。")
                    }
                }
            }
            .navigationTitle("系统日历")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .disabled(isBusy)
            .task { reload() }
            .confirmationDialog("移除本学期已导出的课程？", isPresented: $showRemoveConfirmation, titleVisibility: .visible) {
                Button("移除课程", role: .destructive) { Task { await remove() } }
                Button("取消", role: .cancel) { }
            }
        }
    }

    private func reload() {
        preview = CalendarSyncService.shared.preview(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes)
    }

    private func authorize() async {
        isBusy = true
        defer { isBusy = false }
        do {
            guard try await CalendarSyncService.shared.requestAccess() else {
                report = CalendarSyncReport(errors: ["日历访问尚未允许，可在系统设置中开启。"])
                return
            }
            report = nil
            reload()
        } catch { report = CalendarSyncReport(errors: [error.localizedDescription]) }
    }

    private func synchronize() async {
        isBusy = true
        defer { isBusy = false }
        let result = await CalendarSyncService.shared.sync(semester: semester, occurrences: occurrences, defaultLeadMinutes: defaultLeadMinutes)
        report = result
        if result.errors.isEmpty { onChange(result.coveredIDs, true) }
        reload()
    }

    private func remove() async {
        isBusy = true
        defer { isBusy = false }
        let result = await CalendarSyncService.shared.remove(semester: semester)
        report = result
        if result.errors.isEmpty { onChange(result.coveredIDs, false) }
        reload()
    }
}
