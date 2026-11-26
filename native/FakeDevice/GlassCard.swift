import SwiftUI

/// Liquid Glass card on iOS/macOS 26+, standard material before that.
/// One modifier so every card in the app (iPad and Mac layouts) follows
/// the same rule. The availability check names both platforms explicitly:
/// an iOS-only check would silently take the glass path on macOS.
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

extension View {
    func glassCard() -> some View { modifier(GlassCard()) }
}
