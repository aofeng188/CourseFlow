import XCTest
import CourseKit
@testable import CourseFlow

/// Read-only live checks; annual parser correctness is tested separately with a saved official notice.
@MainActor final class HolidayNetworkTests: XCTestCase {
    func testOfficialNoticeRefresh() async throws {
        let service = HolidayService(cacheURL: nil)
        let semester = Semester(firstMonday: ISO8601DateFormatter().date(from: "2026-09-14T00:00:00+08:00")!, weekCount: 8)
        let started = Date.now
        await service.refresh(for: semester, force: true)
        XCTAssertEqual(service.years[2026]?.days, OfficialHolidayYear.seed2026.days)
        XCTAssertGreaterThan(try XCTUnwrap(service.years[2026]?.checkedAt), started, service.updateMessage)
    }
    func testOfficialSearchDiscoversAnnualNotice() async throws {
        let service = HolidayService(cacheURL: nil)
        let url = try await service.discover(year: 2026)
        XCTAssertTrue(HolidayService.isOfficialURL(url))
        XCTAssertEqual(url.host, "www.gov.cn")
        XCTAssertTrue(url.path.contains("/zhengce/"))
    }
}
