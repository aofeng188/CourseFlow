import SwiftUI
import UIKit

/// Shared by the app, widgets and Live Activities so a course keeps one color everywhere.
///
/// Each course color is tuned separately for light and dark appearance: dark mode keeps the
/// hue's saturation and only raises its lightness, so blocks stay vivid on dark backgrounds
/// instead of fading to gray.
enum Palette {
    /// Brand teal, also the asset catalog's AccentColor.
    static let accent = adaptive(light: 0x0F7A6C, dark: 0x4FCAB6)
    /// The brand teal at full depth in both appearances, for fills that carry white text.
    static let accentSolid = Color(uiColor: uiColor(0x0F7A6C))
    /// "Now" — the current time line and the lesson in progress. Matches the lit block in the app icon.
    static let now = adaptive(light: 0xE5493A, dark: 0xFF6F61)

    /// (light, dark) pairs. The order is stored in each course's `colorIndex`, so only append.
    private static let pairs: [(UInt32, UInt32)] = [
        (0x0F7A6C, 0x4FCAB6), // 青绿
        (0x3563CC, 0x86A9FF), // 蓝
        (0xC2561A, 0xFF9F5E), // 橙
        (0x7351C4, 0xB9A0FF), // 紫
        (0xBC3E6B, 0xFF8DB5), // 玫红
        (0x4A8221, 0x9CD66F), // 绿
        (0x11789C, 0x64C8EA), // 天蓝
        (0x9A7000, 0xF0C24A), // 琥珀
    ]
    static let colors: [Color] = pairs.map { adaptive(light: $0.0, dark: $0.1) }
    private static let solids: [Color] = pairs.map { Color(uiColor: uiColor($0.0)) }
    private static let fills: [Color] = pairs.map { pair in
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? uiColor(pair.1, alpha: 0.2) : uiColor(pair.0, alpha: 0.12)
        })
    }

    private static func wrapped(_ index: Int) -> Int { ((index % pairs.count) + pairs.count) % pairs.count }
    /// Text, icons and accents in the course's color.
    static func color(_ index: Int) -> Color { colors[wrapped(index)] }
    /// A soft background for a course block, tuned per appearance.
    static func fill(_ index: Int) -> Color { fills[wrapped(index)] }
    /// A saturated fill that carries white text in both appearances, used to mark the lesson in progress.
    static func solid(_ index: Int) -> Color { solids[wrapped(index)] }

    private static func uiColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? uiColor(dark) : uiColor(light) })
    }
}
