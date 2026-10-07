import Foundation
import Observation
import WebKit
import CourseKit

@MainActor @Observable final class HolidayService {
    private(set) var years: [Int: OfficialHolidayYear] = [2026: .seed2026]
    private(set) var isRefreshing = false
    private(set) var updateMessage = "内置 2026 年官方安排，离线也可查看"
    private let cacheURL: URL?
    private var attempts: [Int: Date] = [:]
    private struct Cache: Codable { var years: [OfficialHolidayYear]; var attempts: [Int: Date] }
    init(cacheURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("official-holidays.json")) {
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            attempts = cache.attempts
            for year in cache.years where Self.isOfficialURL(URL(string: year.sourceURL)) {
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
                guard !year.days.isEmpty, Set(year.days.map(\.dateKey)).count == year.days.count,
                      year.days.allSatisfy({ HolidayCalendar.date($0.dateKey, calendar: calendar).map { calendar.component(.year, from: $0) == year.year } ?? false }) else { continue }
                years[year.year] = year
            }
        }
    }
    static func isOfficialURL(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, let host = url.host else { return false }
        return host == "gov.cn" || host.hasSuffix(".gov.cn")
    }
    func relevantYears(_ semester: Semester) -> [Int] {
        let last = ScheduleEngine.date(week: semester.weekCount, weekday: 7, semester: semester)
        let firstYear = semester.calendar.component(.year, from: semester.firstMonday)
        let lastYear = semester.calendar.component(.year, from: last)
        return firstYear <= lastYear ? Array(firstYear...lastYear) : [firstYear]
    }
    func days(for semester: Semester) -> [OfficialHolidayDay] {
        relevantYears(semester).flatMap { years[$0]?.days ?? [] }.filter {
            guard let date = $0.date(in: semester) else { return false }
            return (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: date, semester: semester))
        }.sorted { $0.dateKey < $1.dateKey }
    }
    func groups(for semester: Semester) -> [OfficialHolidayGroup] {
        relevantYears(semester).flatMap { years[$0]?.groups ?? [] }
            .filter { !$0.days(in: semester).isEmpty }
            .sorted { ($0.days.first?.dateKey ?? "") < ($1.days.first?.dateKey ?? "") }
    }
    func source(for day: OfficialHolidayDay) -> String { years[Int(day.dateKey.prefix(4)) ?? 0]?.sourceURL ?? "" }
    func day(on date: Date, semester: Semester) -> OfficialHolidayDay? {
        guard semester.holidayHintsEnabled != false else { return nil }
        let key = HolidayCalendar.key(date, calendar: semester.calendar)
        return days(for: semester).first { $0.dateKey == key }
    }
    func missingYears(for semester: Semester) -> [Int] { relevantYears(semester).filter { years[$0] == nil } }
    func refresh(for semester: Semester, force: Bool = false) async {
        guard !isRefreshing, semester.holidayHintsEnabled != false else { return }
        let targets = relevantYears(semester).filter { force || Date.now.timeIntervalSince(attempts[$0] ?? .distantPast) >= 86400 }
        guard !targets.isEmpty else { return }
        isRefreshing = true; defer { isRefreshing = false; saveCache() }
        var updated = 0; var failed = 0
        for year in targets {
            attempts[year] = .now
            do {
                let url: URL
                if let known = years[year], let knownURL = URL(string: known.sourceURL) { url = knownURL }
                else { url = try await discover(year: year) }
                let notice = try await fetch(year: year, url: url)
                guard !Task.isCancelled else { return }
                years[year] = notice; updated += 1
            } catch { failed += 1 }
        }
        if failed > 0 { updateMessage = updated > 0 ? "部分年度已更新；其余年度暂未取得有效公告，已保留已有资料" : "暂未取得有效公告，已保留已有官方安排；可稍后刷新" }
        else { updateMessage = "已核对官方公告 · \(Date.now.formatted(date: .numeric, time: .shortened))" }
    }
    private func saveCache() {
        guard let cacheURL, let data = try? JSONEncoder().encode(Cache(years: Array(years.values), attempts: attempts)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
    private func fetch(year: Int, url: URL) async throws -> OfficialHolidayYear {
        guard Self.isOfficialURL(url) else { throw OfficialHolidayParser.ParseError.invalidNotice }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        request.setValue("CourseFlow/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, Self.isOfficialURL(response.url), data.count <= 5_000_000,
              let html = String(data: data, encoding: .utf8) else { throw OfficialHolidayParser.ParseError.invalidNotice }
        return try OfficialHolidayParser.parse(html: html, year: year, sourceURL: response.url?.absoluteString ?? url.absoluteString)
    }
    /// Use the official site's own search client, so changes to its authentication/API do not require embedded API credentials.
    func discover(year: Int) async throws -> URL {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
        var components = URLComponents(string: "https://sousuo.www.gov.cn/sousuo/search.shtml")!
        components.queryItems = [URLQueryItem(name: "code", value: "17da70961a7"), URLQueryItem(name: "dataTypeId", value: "107"), URLQueryItem(name: "searchWord", value: "国务院办公厅关于\(year)年部分节假日安排的通知")]
        web.load(URLRequest(url: components.url!, timeoutInterval: 15))
        defer { web.stopLoading() }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(750))
            let links = try? await web.evaluateJavaScript("Array.from(document.querySelectorAll('a[href]')).map(a => ({title:a.textContent.replace(/\\s/g,''),url:a.href}))")
            if let links = links as? [[String: String]] {
                for link in links where link["title"]?.contains("国务院办公厅关于\(year)年部分节假日安排的通知") == true {
                    if let value = link["url"], let url = URL(string: value), Self.isOfficialURL(url), url.host == "www.gov.cn", url.path.contains("/zhengce/") { return url }
                }
            }
        }
        throw OfficialHolidayParser.ParseError.invalidNotice
    }
}
