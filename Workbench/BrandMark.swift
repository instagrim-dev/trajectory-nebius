import SwiftUI

/// The Returning Stair emblem, served from the `ReturningStair` image set
/// (byte-identical copy of `Brand/returning-stair-transparent.png`).
/// The asset keeps its alpha: no baked paper canvas or tile.
struct BrandMark: View {
    var size: CGFloat

    var body: some View {
        Image("ReturningStair")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Returning Stair emblem")
    }
}
