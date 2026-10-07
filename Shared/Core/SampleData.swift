import Foundation

public enum SampleData {
    /// Call only after the user explicitly chooses to load an example timetable.
    public static func make(now: Date = .now) -> ScheduleSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let weekday = (calendar.component(.weekday, from: now) + 5) % 7
        let currentMonday = calendar.date(byAdding: .day, value: -weekday, to: calendar.startOfDay(for: now))!
        let semester = Semester(name: "示例学期", firstMonday: calendar.date(byAdding: .day, value: -21, to: currentMonday)!, weekCount: 18)
        let bell = BellSchedule(semesterID: semester.id, name: "示例学校作息", effectiveFrom: semester.firstMonday, periods: [
            Period(number: 1, startMinute: 480, endMinute: 525),
            Period(number: 2, startMinute: 535, endMinute: 580),
            Period(number: 3, startMinute: 600, endMinute: 645),
            Period(number: 4, startMinute: 655, endMinute: 700),
            Period(number: 5, startMinute: 840, endMinute: 885),
            Period(number: 6, startMinute: 895, endMinute: 940),
            Period(number: 7, startMinute: 960, endMinute: 1005),
            Period(number: 8, startMinute: 1015, endMinute: 1060),
            Period(number: 9, startMinute: 1140, endMinute: 1185),
            Period(number: 10, startMinute: 1195, endMinute: 1240)
        ], isConfirmed: true)
        let math = Course(semesterID: semester.id, name: "高等数学", colorIndex: 0)
        let english = Course(semesterID: semester.id, name: "大学英语", colorIndex: 1)
        let physics = Course(semesterID: semester.id, name: "大学物理", colorIndex: 2)
        let code = Course(semesterID: semester.id, name: "程序设计", colorIndex: 3)
        let sports = Course(semesterID: semester.id, name: "体育", colorIndex: 4, reminderMinutes: 20)
        let art = Course(semesterID: semester.id, name: "艺术鉴赏", colorIndex: 5)
        let all = Array(1...18)
        let rules = [
            MeetingRule(courseID: math.id, weekday: 1, weeks: all, periodNumbers: [1, 2], location: "明德楼 A301", teacher: "陈老师"),
            MeetingRule(courseID: math.id, weekday: 4, weeks: all, periodNumbers: [3, 4], location: "明德楼 A301", teacher: "陈老师"),
            MeetingRule(courseID: english.id, weekday: 2, weeks: all, periodNumbers: [3, 4], location: "博学楼 B205", teacher: "李老师"),
            MeetingRule(courseID: english.id, weekday: 5, weeks: all, periodNumbers: [1, 2], location: "博学楼 B205", teacher: "李老师"),
            MeetingRule(courseID: physics.id, weekday: 3, weeks: Array(1...8), periodNumbers: [1, 2], location: "理科楼 402", teacher: "王老师"),
            MeetingRule(courseID: physics.id, weekday: 5, weeks: Array(stride(from: 2, through: 18, by: 2)), periodNumbers: [5, 6], location: "实验楼 201", teacher: "王老师"),
            MeetingRule(courseID: code.id, weekday: 1, weeks: all, periodNumbers: [5, 6], location: "信息楼 503", teacher: "张老师"),
            MeetingRule(courseID: code.id, weekday: 4, weeks: all, periodNumbers: [7, 8], location: "计算机中心 302", teacher: "张老师"),
            MeetingRule(courseID: sports.id, weekday: 2, weeks: all, periodNumbers: [7, 8], location: "南区体育馆", teacher: "刘老师"),
            MeetingRule(courseID: art.id, weekday: 3, weeks: Array(stride(from: 1, through: 17, by: 2)), periodNumbers: [9, 10], location: "艺术楼 101", teacher: "周老师")
        ]
        return ScheduleSnapshot(semesters: [semester], bellSchedules: [bell], courses: [math, english, physics, code, sports, art], rules: rules)
    }
}
