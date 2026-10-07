import Foundation

public struct HolidayDecision: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case keepSchedule, noClasses }
    public var id: UUID
    public var semesterID: UUID
    public var date: Date
    public var kind: Kind
    public var sourceURL: String
    public init(id: UUID = UUID(), semesterID: UUID, date: Date, kind: Kind, sourceURL: String) {
        self.id = id; self.semesterID = semesterID; self.date = date; self.kind = kind; self.sourceURL = sourceURL
    }
}

public struct OfficialHolidayDay: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case holiday, makeup }
    public var dateKey: String
    public var name: String
    public var kind: Kind
    public var id: String { dateKey }
    public init(dateKey: String, name: String, kind: Kind) { self.dateKey = dateKey; self.name = name; self.kind = kind }
    public func date(in semester: Semester) -> Date? { HolidayCalendar.date(dateKey, calendar: semester.calendar) }
}

/// A complete festival from one annual notice, including makeup dates on either side of its holiday.
/// Groups are derived from the official cache; school decisions remain stored per day.
public struct OfficialHolidayGroup: Hashable, Identifiable, Sendable {
    public var year: Int
    public var name: String
    public var days: [OfficialHolidayDay]
    public var id: String { "\(year)-\(name)" }
    public init(year: Int, name: String, days: [OfficialHolidayDay]) {
        self.year = year; self.name = name; self.days = days.sorted { $0.dateKey < $1.dateKey }
    }
    public func days(in semester: Semester) -> [OfficialHolidayDay] {
        days.filter {
            guard let date = $0.date(in: semester) else { return false }
            return (1...semester.weekCount).contains(ScheduleEngine.weekNumber(on: date, semester: semester))
        }
    }
}

public struct OfficialHolidayYear: Codable, Equatable, Sendable {
    public var year: Int
    public var title: String
    public var sourceURL: String
    public var checkedAt: Date
    public var days: [OfficialHolidayDay]
    public init(year: Int, title: String, sourceURL: String, checkedAt: Date = .now, days: [OfficialHolidayDay]) {
        self.year = year; self.title = title; self.sourceURL = sourceURL; self.checkedAt = checkedAt; self.days = days
    }
    public var groups: [OfficialHolidayGroup] {
        Dictionary(grouping: days, by: \.name).map { name, days in
            OfficialHolidayGroup(year: year, name: name, days: days)
        }.sorted {
            let first = $0.days.first?.dateKey ?? ""
            let second = $1.days.first?.dateKey ?? ""
            return first == second ? $0.name < $1.name : first < second
        }
    }
    public static var seed2026: OfficialHolidayYear {
        var days: [OfficialHolidayDay] = []
        for (name, month, first, last) in [("元旦",1,1,3), ("春节",2,15,23), ("清明节",4,4,6), ("劳动节",5,1,5), ("端午节",6,19,21), ("中秋节",9,25,27), ("国庆节",10,1,7)] {
            for day in first...last { days.append(.init(dateKey: String(format: "2026-%02d-%02d", month, day), name: name, kind: .holiday)) }
        }
        for (name,month,day) in [("元旦",1,4),("春节",2,14),("春节",2,28),("劳动节",5,9),("国庆节",9,20),("国庆节",10,10)] {
            days.append(.init(dateKey: String(format: "2026-%02d-%02d",month,day), name: name, kind: .makeup))
        }
        return .init(year: 2026, title: "国务院办公厅关于2026年部分节假日安排的通知", sourceURL: "https://www.gov.cn/zhengce/content/202511/content_7047090.htm", checkedAt: Date(timeIntervalSince1970: 1790812800), days: days.sorted { $0.dateKey < $1.dateKey })
    }
}

public enum HolidayCalendar {
    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let fields = key.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3, (1900...2200).contains(fields[0]), (1...12).contains(fields[1]), (1...31).contains(fields[2]),
              let date = calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2])),
              calendar.component(.month, from: date) == fields[1], calendar.component(.day, from: date) == fields[2] else { return nil }
        return date
    }
    public static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",c.year ?? 0,c.month ?? 0,c.day ?? 0)
    }
    public static func hasArrangement(_ date: Date, semester: Semester, snapshot: ScheduleSnapshot) -> Bool {
        snapshot.dayOverrides.contains { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }
            || snapshot.holidayDecisions.contains { $0.semesterID == semester.id && semester.calendar.isDate($0.date, inSameDayAs: date) }
    }
    public static func isPending(_ day: OfficialHolidayDay, semester: Semester, snapshot: ScheduleSnapshot) -> Bool {
        guard semester.holidayHintsEnabled != false, let date = day.date(in: semester) else { return false }
        let week = ScheduleEngine.weekNumber(on: date, semester: semester)
        guard (1...semester.weekCount).contains(week) else { return false }
        return !hasArrangement(date, semester: semester, snapshot: snapshot)
    }
    public static func shouldPrompt(_ day: OfficialHolidayDay, now: Date, semester: Semester, snapshot: ScheduleSnapshot) -> Bool {
        guard isPending(day, semester: semester, snapshot: snapshot), let date = day.date(in: semester),
              let distance = semester.calendar.dateComponents([.day], from: semester.calendar.startOfDay(for: now), to: date).day else { return false }
        return (0...7).contains(distance)
    }
    public static func shouldPrompt(_ group: OfficialHolidayGroup, now: Date, semester: Semester, snapshot: ScheduleSnapshot) -> Bool {
        guard semester.holidayHintsEnabled != false,
              let first = group.days.compactMap({ $0.date(in: semester) }).min(),
              let opens = semester.calendar.date(byAdding: .day, value: -7, to: first) else { return false }
        let today = semester.calendar.startOfDay(for: now)
        guard today >= opens else { return false }
        return group.days(in: semester).contains { day in
            guard let date = day.date(in: semester), date >= today else { return false }
            return isPending(day, semester: semester, snapshot: snapshot)
        }
    }
}

/// A deliberately strict annual-notice parser. A new template stays unavailable until it can be verified.
public enum OfficialHolidayParser {
    public enum ParseError: Error { case invalidNotice }
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    public static func text(from html: String) -> String {
        var result = html.replacingOccurrences(of: "<script\\b[^>]*>.*?</script>|<style\\b[^>]*>.*?</style>", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for value in ["&nbsp;", "&#160;", "\u{00a0}", "&ensp;", "&emsp;"] { result = result.replacingOccurrences(of: value, with: " ") }
        return result.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
    public static func parse(html: String, year: Int, sourceURL: String) throws -> OfficialHolidayYear {
        let text = text(from: html)
        guard URL(string: sourceURL)?.scheme == "https", let host = URL(string: sourceURL)?.host,
              host == "gov.cn" || host.hasSuffix(".gov.cn"), text.contains("国务院办公厅关于\(year)年"), text.contains("部分节假日安排的通知") else { throw ParseError.invalidNotice }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var days: [OfficialHolidayDay] = []
        let clauses = matches("[一二三四五六七]、(元旦|春节|清明节|劳动节|端午节|中秋节|国庆节)：(.*?)(?=[一二三四五六七]、(?:元旦|春节|清明节|劳动节|端午节|中秋节|国庆节)：|鼓励|节假日期间|国务院办公厅|$)", text)
        let names: Set<String> = ["元旦","春节","清明节","劳动节","端午节","中秋节","国庆节"]
        guard clauses.count == 7, Set(clauses.map { $0[1] }) == names else { throw ParseError.invalidNotice }
        func dates(_ value: String) throws -> [Date] {
            var month: Int?; var result: [Date] = []
            for token in matches("(?:(\\d{1,2})月)?(\\d{1,2})日(?:[（(]([^）)]*)[）)])?", value) {
                if let m = Int(token[1]) { month = m }
                guard let month, let d = Int(token[2]), let date = HolidayCalendar.date(String(format: "%04d-%02d-%02d",year,month,d), calendar: calendar) else { throw ParseError.invalidNotice }
                let weekday = matches("周([一二三四五六日天])", token[3]).first?[1]
                if let weekday {
                    let actual = (calendar.component(.weekday, from: date) + 5) % 7
                    guard ["一","二","三","四","五","六","日"][actual] == (weekday == "天" ? "日" : weekday) else { throw ParseError.invalidNotice }
                }
                result.append(date)
            }
            return result
        }
        for clause in clauses {
            guard let range = clause[2].range(of: "放假") else { throw ParseError.invalidNotice }
            let endpoints = try dates(String(clause[2][..<range.lowerBound]))
            guard (1...2).contains(endpoints.count), let first = endpoints.first, let last = endpoints.last, first <= last,
                  let countText = matches("共(\\d+)天", clause[2]).first?[1], let count = Int(countText),
                  calendar.dateComponents([.day], from: first, to: last).day == count - 1, (1...15).contains(count) else { throw ParseError.invalidNotice }
            for offset in 0..<count {
                guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { throw ParseError.invalidNotice }
                days.append(.init(dateKey: HolidayCalendar.key(date, calendar: calendar), name: clause[1], kind: .holiday))
            }
            // Only sentences explicitly ending in 上班 are makeup dates.
            for sentence in clause[2].split(separator: "。") where sentence.hasSuffix("上班") {
                for date in try dates(String(sentence)) { days.append(.init(dateKey: HolidayCalendar.key(date, calendar: calendar), name: clause[1], kind: .makeup)) }
            }
        }
        guard Set(days.map(\.dateKey)).count == days.count else { throw ParseError.invalidNotice }
        return .init(year: year, title: "国务院办公厅关于\(year)年部分节假日安排的通知", sourceURL: sourceURL, days: days.sorted { $0.dateKey < $1.dateKey })
    }
}
