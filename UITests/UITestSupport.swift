import XCTest

/// Queries that hold on every iPhone layout. A folded iPhone Duo moves the tab buttons, the
/// navigation bar's buttons and the search field into a vertical toolbar beside the content.
extension XCUIApplication {
    @MainActor func tab(_ title: String) -> XCUIElement {
        let button = tabBars.buttons[title]
        return button.exists ? button : toolbars.buttons[title].firstMatch
    }
    @MainActor func barButton(_ title: String) -> XCUIElement {
        let button = navigationBars.buttons[title]
        if button.exists { return button }
        let vertical = toolbars.buttons[title].firstMatch
        return vertical.exists ? vertical : sheetBarButton(title).firstMatch
    }
    /// The search field, opened from the toolbar's search button when it starts out collapsed.
    @MainActor func openSearchField() -> XCUIElement {
        let field = searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { toolbars.buttons["搜索"].firstMatch.tap() }
        return field
    }
    /// A button in a sheet's navigation bar. A folded iPhone Duo tucks that bar away while
    /// the content is scrolled down; a short pull on the leading margin brings it back.
    @MainActor func sheetBarButton(_ identifier: String) -> XCUIElement {
        let button = buttons[identifier]
        if !button.exists {
            let origin = coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 12, dy: 200)).press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 12, dy: 260)), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        return button
    }
    /// A horizontal position near the trailing edge of the scrolling content, left of a vertical toolbar.
    @MainActor var contentTrailingX: CGFloat {
        let rail = toolbars.buttons["课表"].firstMatch
        return !tabBars.firstMatch.exists && rail.exists ? rail.frame.minX - 50 : frame.width * 0.88
    }
}
