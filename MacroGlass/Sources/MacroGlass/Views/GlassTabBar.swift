import SwiftUI

/// The tabs inside Macro mode. The auto clicker isn't one of them — it's
/// its own mode, picked at the start, so it doesn't drag Script and
/// Settings along with it.
enum AppTab: String, CaseIterable, Identifiable {
    case record = "Record"
    case script = "Script"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .record: return "record.circle"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .settings: return "gearshape"
        }
    }
}

/// Separate glass pills — no shared container, no merging. Each tab is its
/// own pane with its own rim, sheen and shadow.
struct GlassTabBar: View {
    @Binding var selection: AppTab
    var tint: Color
    /// A green dot on the Record pill while a macro is playing, so it's
    /// visible from the Script and Settings tabs too.
    var activeTab: AppTab?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selection = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if activeTab == tab {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                .buttonStyle(.glass(
                    tint: selection == tab ? tint : nil,
                    capsule: true,
                    horizontalPadding: 12
                ))
            }
        }
    }
}
