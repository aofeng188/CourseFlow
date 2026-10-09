import SwiftUI

/// Picks an IANA time zone by city name instead of typing identifiers such as "Asia/Shanghai".
struct TimeZonePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""
    private static let locale = Locale(identifier: "zh_CN")
    /// Zones most schools using this app are in, shown before the full list.
    private static let common = ["Asia/Shanghai", "Asia/Hong_Kong", "Asia/Macau", "Asia/Taipei", "Asia/Singapore",
                                 "Asia/Tokyo", "Asia/Seoul", "Europe/London", "Europe/Berlin", "America/New_York",
                                 "America/Los_Angeles", "Australia/Sydney"]

    static func title(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        return zone.localizedName(for: .generic, locale: locale) ?? identifier
    }

    private static func offset(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return "" }
        let seconds = zone.secondsFromGMT()
        let sign = seconds < 0 ? "-" : "+"
        let minutes = abs(seconds) / 60
        return minutes % 60 == 0 ? "GMT\(sign)\(minutes / 60)" : String(format: "GMT%@%d:%02d", sign, minutes / 60, minutes % 60)
    }

    private func matches(_ identifier: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return identifier.localizedStandardContains(text) || Self.title(for: identifier).localizedStandardContains(text)
            || identifier.replacingOccurrences(of: "_", with: " ").localizedStandardContains(text)
    }

    var body: some View {
        let common = Self.common.filter(matches)
        let all = TimeZone.knownTimeZoneIdentifiers.filter { !Self.common.contains($0) && matches($0) }
        List {
            if !common.isEmpty { Section("常用") { ForEach(common, id: \.self, content: row) } }
            if !all.isEmpty { Section("全部时区") { ForEach(all, id: \.self, content: row) } }
        }
        .overlay { if common.isEmpty && all.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, prompt: "城市或时区")
        .navigationTitle("学校时区").navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ identifier: String) -> some View {
        Button { selection = identifier; dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(for: identifier)).foregroundStyle(.primary)
                    Text("\(identifier) · \(Self.offset(for: identifier))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if identifier == selection { Image(systemName: "checkmark").foregroundStyle(Palette.accent).fontWeight(.semibold) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(identifier == selection ? .isSelected : [])
    }
}
