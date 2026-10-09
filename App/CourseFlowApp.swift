import SwiftUI
import SwiftData
import CourseKit

@main struct CourseFlowApp: App {
    @State private var store: AppStore?
    @State private var startupError: String?
    init() {
        do {
            let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
            let persistence = try Persistence(inMemory: testing)
            let hostedTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let value = try AppStore(persistence: persistence, systemIntegrationsEnabled: !hostedTest)
            ScheduleBackgroundRefresh.register {
                await value.reload(forceRefresh: true)
                await value.waitForRefresh()
                return true
            }
            if ProcessInfo.processInfo.arguments.contains("--demo") { value.loadExample(now: PreviewClock.fixedDate ?? .now) }
            AppStore.current = value
            _store = State(initialValue: value)
        } catch { _startupError = State(initialValue: error.localizedDescription) }
    }
    var body: some Scene {
        WindowGroup {
            if let store {
                RootView()
                    .transformEnvironment(\.dynamicTypeSize) { size in
                        if ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--preview-large-type") { size = .accessibility3 }
                    }
                    .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--uitesting") && ProcessInfo.processInfo.arguments.contains("--preview-dark") ? .dark : nil)
                    .environment(store).modelContainer(store.persistence.container).tint(Palette.accent).environment(\.locale, Locale(identifier: "zh_CN"))
            } else {
                ContentUnavailableView("无法打开课表资料", systemImage: "externaldrive.badge.exclamationmark", description: Text(startupError ?? "请重新打开 App。原有资料不会被清空。"))
            }
        }
    }
}

private enum RootSheet: Identifiable {
    case importing, semester(Semester?), course(Course?, Occurrence?)
    var id: String { switch self { case .importing: "import"; case .semester(let value): "semester-\(value?.id.uuidString ?? "new")"; case .course(let value, let occurrence): "course-\(value?.id.uuidString ?? "new")-\(occurrence?.id ?? "")" } }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Query private var records: [StoredRecord]
    @State private var tab = 0
    @State private var sheet: RootSheet?
    @State private var incomingBackup: ScheduleSnapshot?
    @State private var confirmRestore = false
    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("课表", systemImage: "calendar", value: 0) {
                NavigationStack {
                    TimetableView(onImport: importAction, onSetup: { sheet = .semester(nil) }, onCourse: openCourse)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { addMenu } }
                }
            }
            Tab("课程", systemImage: "books.vertical", value: 1) {
                NavigationStack {
                    CourseListView(onCourse: { course in sheet = .course(course, nil) })
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { addMenu } }
                }
            }
            Tab("设置", systemImage: "gearshape", value: 2) {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(item: $sheet) { value in
            switch value {
            case .importing:
                ImportFlowView(semester: store.semester, bellSchedules: store.bells) { draft, replaceDuplicates in
                    store.commitImport(draft, replaceDuplicates: replaceDuplicates)
                }
            case .semester(let value): SemesterEditor(semester: value)
            case .course(let value, let occurrence):
                if let value { CourseDetailView(courseID: value.id, occurrence: occurrence) }
                else if let semester = store.semester { CourseEditor(semester: semester) }
            }
        }
        .alert("未能完成操作", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) { Button("知道了") { store.errorMessage = nil } } message: { Text(store.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if let notice = store.notice {
                Text(notice).font(.subheadline).padding(.horizontal, 20).padding(.vertical, 12).glassEffect().padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: notice) { try? await Task.sleep(for: .seconds(3)); if store.notice == notice { store.notice = nil } }
            }
        }
        .task(id: store.semester?.id) {
            if !ProcessInfo.processInfo.arguments.contains("--uitesting"), let semester = store.semester { await store.holidays.refresh(for: semester) }
        }
        .onChange(of: recordsSignature) { store.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.reload(forceRefresh: true); if !ProcessInfo.processInfo.arguments.contains("--uitesting"), let semester = store.semester { Task { await store.holidays.refresh(for: semester) } } }
            if phase == .background { try? ScheduleBackgroundRefresh.schedule() }
        }
        .onOpenURL { url in
            if url.scheme == "courseflow" || url.scheme == "courseflow-trial" {
                tab = 0
                if url.host == "course", let id = UUID(uuidString: url.lastPathComponent), let course = store.snapshot.courses.first(where: { $0.id == id }) { sheet = .course(course, nil) }
            } else if url.isFileURL {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do { incomingBackup = try BackupCodec.decode(Data(contentsOf: url)); confirmRestore = true } catch { store.errorMessage = error.localizedDescription }
            }
        }
        .alert("恢复课表备份？", isPresented: $confirmRestore) {
            Button("取消", role: .cancel) { incomingBackup = nil }
            Button("备份当前资料并恢复") { do { if let incomingBackup { try store.restore(incomingBackup) } } catch { store.errorMessage = error.localizedDescription }; incomingBackup = nil }
        } message: { Text("备份中包含 \(incomingBackup?.semesters.count ?? 0) 个学期、\(incomingBackup?.courses.count ?? 0) 门课程。当前资料会先自动备份。") }
    }
    /// Changes whenever any record is inserted, edited or deleted, locally or by sync.
    /// Summing per-record hashes is order-independent, so the query result needs no sorting.
    private var recordsSignature: Int {
        records.reduce(records.count) { total, record in
            var hasher = Hasher()
            hasher.combine(record.entityID); hasher.combine(record.modifiedAt); hasher.combine(record.isDeleted)
            return total &+ hasher.finalize()
        }
    }
    private var addMenu: some View {
        Menu {
            Button("导入课表或作息", systemImage: "square.and.arrow.down", action: importAction)
            Button("手动添加课程", systemImage: "plus") { sheet = store.semester == nil ? .semester(nil) : .course(nil, nil) }
            Button("添加学期", systemImage: "calendar.badge.plus") { sheet = .semester(nil) }
        } label: { Image(systemName: "plus").accessibilityLabel("添加") }.accessibilityIdentifier("add-menu")
    }
    private func importAction() { sheet = store.semester == nil ? .semester(nil) : .importing }
    private func openCourse(_ occurrence: Occurrence) { if let course = store.snapshot.courses.first(where: { $0.id == occurrence.courseID }) { sheet = .course(course, occurrence) } }
}
