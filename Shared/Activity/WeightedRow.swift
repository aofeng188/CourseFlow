import SwiftUI

/// A row that splits its width between children by weight, e.g. one bar per teaching segment
/// of a back-to-back lesson with a small gap where each break falls.
struct WeightedRow: Layout {
    var weights: [Double]
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 120, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let total = zip(weights, subviews).reduce(0) { $0 + max(0, $1.0) }
        let available = max(0, bounds.width - spacing * CGFloat(max(0, subviews.count - 1)))
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let share = total > 0 && index < weights.count ? max(0, weights[index]) / total : 1 / Double(subviews.count)
            let width = available * share
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
