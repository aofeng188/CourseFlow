import SwiftUI
import UIKit

/// Shared by the app, widgets and Live Activities so a course keeps one color everywhere.
enum Palette {
    static let accent = adaptive(0.08, 0.48, 0.43)
    static let colors: [Color] = [accent, adaptive(0.28, 0.42, 0.74), adaptive(0.68, 0.38, 0.24), adaptive(0.49, 0.37, 0.68), adaptive(0.67, 0.38, 0.51), adaptive(0.43, 0.51, 0.25), adaptive(0.21, 0.51, 0.64), adaptive(0.64, 0.49, 0.19)]
    static func color(_ index: Int) -> Color { colors[((index % colors.count) + colors.count) % colors.count] }
    private static func adaptive(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(uiColor: UIColor { traits in
            let lift = traits.userInterfaceStyle == .dark ? 0.48 : 0.0
            return UIColor(red: red + (1 - red) * lift, green: green + (1 - green) * lift, blue: blue + (1 - blue) * lift, alpha: 1)
        })
    }
}
