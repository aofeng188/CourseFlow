import Foundation
import Testing
@testable import CourseKit

struct ExportPreferencesTests {
    @Test func backupDoesNotTransferCalendarWriterDevice() throws {
        var snapshot = SampleData.make(now: .now)
        snapshot.semesters[0].calendarOwnerDeviceID = "local-device-only"
        let restored = try BackupCodec.decode(BackupCodec.encode(snapshot))
        #expect(restored.semesters[0].calendarOwnerDeviceID == nil)
        #expect(restored.courses == snapshot.courses)
    }
    @Test func icsUsesGlobalReminderAndCourseOverride() throws {
        let snapshot = SampleData.make(now: .now)
        let semester = try #require(snapshot.semesters.first)
        var event = try #require(ScheduleEngine.occurrences(snapshot: snapshot, semesterID: semester.id).first)
        event.reminderMinutes = nil
        #expect(ICSExporter.export(occurrences: [event], semester: semester, defaultLeadMinutes: 30).contains("TRIGGER:-PT30M"))
        event.reminderMinutes = 5
        #expect(ICSExporter.export(occurrences: [event], semester: semester, defaultLeadMinutes: 30).contains("TRIGGER:-PT5M"))
        event.reminderMinutes = -1
        #expect(!ICSExporter.export(occurrences: [event], semester: semester, defaultLeadMinutes: 30).contains("BEGIN:VALARM"))
    }
}
