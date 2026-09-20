import SwiftUI

/// What the app is being used for this session. The two halves barely
/// overlap in practice — recording a macro and setting up a click loop are
/// different jobs — so asking once up front keeps each side uncluttered
/// instead of showing everyone every tab.
enum AppMode: String, CaseIterable, Identifiable, Codable {
    case macro
    case clicker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macro: return "Macro"
        case .clicker: return "Auto clicker"
        }
    }

    var symbol: String {
        switch self {
        case .macro: return "record.circle"
        case .clicker: return "cursorarrow.click.2"
        }
    }

    var blurb: String {
        switch self {
        case .macro: return "Record what you do, then replay it. Scripts and settings live here too."
        case .clicker: return "Click or press a key on a timer, anywhere on screen, until you stop it."
        }
    }

    var detail: String {
        switch self {
        case .macro: return "Record · Script · Settings"
        case .clicker: return "Nothing else in the way"
        }
    }
}

/// Where the app opens. Ask every time by default; pin it to one side once
/// you know which one you actually use.
enum StartupMode: String, CaseIterable, Identifiable {
    case ask
    case macro
    case clicker

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ask: return "Ask me"
        case .macro: return "Macro"
        case .clicker: return "Auto clicker"
        }
    }

    var appMode: AppMode? {
        switch self {
        case .ask: return nil
        case .macro: return .macro
        case .clicker: return .clicker
        }
    }
}

// MARK: - The screen

struct ModeChooserView: View {
    @ObservedObject var settings: AppSettings
    var onChoose: (AppMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            VStack(spacing: 5) {
                Text("MacroGlass")
                    .font(.system(size: 21, weight: .semibold))
                Text("What are you here for?")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 22)

            HStack(spacing: 12) {
                ForEach(AppMode.allCases) { mode in
                    ModeCard(mode: mode, tint: settings.tint) { onChoose(mode) }
                }
            }

            Spacer(minLength: 22)

            HStack(spacing: 8) {
                Text("Open to")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(StartupMode.allCases) { option in
                        Button(option.label) { settings.startupMode = option }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(settings.startupMode.label)
                            .font(.system(size: 11.5, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .glass(Capsule(), style: .control)

                Text("next time")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if !AccessibilityPermission.isTrusted {
                permissionNote
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private var permissionNote: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
            Text("Both sides need Accessibility access to touch the keyboard and mouse.")
                .font(.system(size: 10.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button("Grant") {
                AccessibilityPermission.requestPrompt()
                AccessibilityPermission.openSystemSettings()
            }
            .buttonStyle(.glass(capsule: true))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glass(RoundedRectangle(cornerRadius: 13, style: .continuous), style: .panel)
    }
}

// MARK: - One card

private struct ModeCard: View {
    let mode: AppMode
    let tint: Color
    var action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    private var glass: GlassStyle {
        var base = GlassStyle.panel
        if isHovering { base = base.tinted(tint, opacity: 0.22).amplified(1.35) }
        return base
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(isHovering ? Color.white : tint)
                    .frame(height: 30)

                Spacer(minLength: 14)

                Text(mode.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isHovering ? Color.white : Color.primary)

                Text(mode.blurb)
                    .font(.system(size: 11))
                    .foregroundStyle(isHovering ? Color.white.opacity(0.85) : Color.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)

                Spacer(minLength: 10)

                Text(mode.detail.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(isHovering ? Color.white.opacity(0.7) : Color.tertiaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 150)
            .padding(.horizontal, 15)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .glass(RoundedRectangle(cornerRadius: 16, style: .continuous), style: glass, isPressed: isPressed)
        .scaleEffect(isPressed ? 0.98 : (isHovering ? 1.015 : 1))
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isHovering)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
        .onHover { isHovering = $0 }
        // A plain button style gives no press state, and these cards are
        // big enough that a press needs to register somehow.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

private extension Color {
    /// `.tertiary` is a ShapeStyle, not a Color, so it can't sit in a
    /// ternary next to a real Color.
    static var tertiaryLabel: Color { Color.secondary.opacity(0.6) }
}
