import Testing
@testable import CourseKit

@Suite("周课表按节次排布")
struct TimelineScaleTests {
    private let metrics = TimelineScale.Metrics(periodHeight: 50, gapHeight: 4, longBreakHeight: 20, longBreakMinutes: 30)
    /// 1–4 节在上午，课间 10 和 20 分钟；午休 140 分钟后第 5 节。
    private let periods = [
        Period(number: 1, startMinute: 480, endMinute: 525), Period(number: 2, startMinute: 535, endMinute: 580),
        Period(number: 3, startMinute: 600, endMinute: 645), Period(number: 4, startMinute: 655, endMinute: 700),
        Period(number: 5, startMinute: 840, endMinute: 885),
    ]

    @Test func periodsShareOneHeightAndBreaksCollapse() {
        let scale = TimelineScale(periods: periods, lessons: [480..<580], metrics: metrics)
        #expect(scale.segments.map(\.kind) == [.period(1), .gap, .period(2), .gap, .period(3), .gap, .period(4), .longBreak, .period(5)])
        #expect(scale.y(at: 480) == 0)
        #expect(scale.y(at: 525) == 50)
        #expect(scale.y(at: 535) == 54)
        #expect(scale.y(at: 700) == 4 * 50 + 3 * 4)
        #expect(scale.y(at: 840) == 4 * 50 + 3 * 4 + 20)
        #expect(scale.height == 5 * 50 + 3 * 4 + 20)
    }

    @Test func minutesInsideAPeriodAreProportional() {
        let scale = TimelineScale(periods: periods, lessons: [], metrics: metrics)
        #expect(abs(scale.y(at: 480 + 18) - 20) < 0.001)
        #expect(scale.segment(containing: 500)?.kind == .period(1))
        #expect(scale.segment(containing: 530)?.kind == .gap)
        #expect(scale.segment(containing: 885) == nil)
    }

    @Test func aLessonInsideLunchKeepsRealHeight() {
        let scale = TimelineScale(periods: periods, lessons: [720..<780], metrics: metrics)
        let lunch = scale.segment(containing: 750)
        #expect(lunch?.kind == .open)
        // 50 pt per 45-minute period.
        #expect(abs((scale.y(at: 780) - scale.y(at: 720)) - 60 * 50 / 45.0) < 0.001)
    }

    @Test func aLessonSpanningBreaksDoesNotOpenThem() {
        let scale = TimelineScale(periods: periods, lessons: [480..<885], metrics: metrics)
        #expect(!scale.segments.contains { $0.kind == .open })
    }

    @Test func lessonsOutsideTheScheduleExtendIt() {
        let scale = TimelineScale(periods: periods, lessons: [420..<465, 900..<990], metrics: metrics)
        #expect(scale.startMinute == 420)
        #expect(scale.endMinute == 990)
        #expect(scale.segments.first?.kind == .open)
        #expect(scale.segments.last?.kind == .open)
        #expect(scale.y(at: 480) > scale.y(at: 465))
    }

    @Test func withoutABellScheduleHoursBecomeRows() {
        let scale = TimelineScale(periods: [], lessons: [1170..<1230], metrics: metrics)
        #expect(scale.startMinute == 480)
        #expect(scale.endMinute == 1260)
        #expect(scale.segments.allSatisfy { $0.kind == .hour && $0.height == 50 })
        #expect(TimelineScale(periods: [], lessons: [], metrics: metrics).endMinute == 1080)
    }

    @Test func overlappingAndEmptyPeriodsAreTolerated() {
        let messy = [Period(number: 2, startMinute: 520, endMinute: 560), Period(number: 1, startMinute: 480, endMinute: 525), Period(number: 3, startMinute: 600, endMinute: 600)]
        let scale = TimelineScale(periods: messy, lessons: [], metrics: metrics)
        #expect(scale.segments.map(\.kind) == [.period(1), .period(2)])
        #expect(scale.segments[1].startMinute == 525)
        #expect(scale.y(at: 9999) == scale.height)
        #expect(scale.y(at: 0) == 0)
    }
}
