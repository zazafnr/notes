import SwiftUI

/// Kurzer Hinweis oben, wenn wieder 0,50 $ Claude-Kosten zusammengekommen sind.
struct CostToast: ViewModifier {
    @EnvironmentObject private var settings: AISettings

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = settings.costNotice {
                    Label(notice, systemImage: "dollarsign.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Theme.aiGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onTapGesture { settings.costNotice = nil }
                        .task(id: notice) {
                            try? await Task.sleep(nanoseconds: 3_500_000_000)
                            settings.costNotice = nil
                        }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: settings.costNotice)
    }
}

extension View {
    func costToast() -> some View { modifier(CostToast()) }
}
