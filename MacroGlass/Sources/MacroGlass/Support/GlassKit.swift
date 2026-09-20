import SwiftUI
import AppKit

// MARK: - Backdrop blur
//
// Our own blur layer, backed by NSVisualEffectView. Everything glassy in
// this app is built on top of this plus the gradient stack in
// GlassSurface below — no system "glass effect" API is used anywhere.

struct BackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = InertVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
    }
}

/// Glass panes live in `.background()`, so an AppKit view sits underneath
/// every text field, row and button in the app. `NSVisualEffectView` is a
/// real view: it answers hit tests and volunteers to drag the window. Both
/// of those steal clicks that were meant for the control in front of it —
/// which is why clicking the padding around the script-name field, or the
/// blank part of the editor, did nothing. Refusing hit tests outright makes
/// the glass purely decorative, and clicks fall through to the control.
private final class InertVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Glass recipe

/// The knobs that define one glass surface: how much color sits in the
/// pane, how strong the specular sheen is, how bright the lit edge is,
/// and how far it floats off the background.
struct GlassStyle {
    var tint: Color?
    var tintOpacity: Double
    var sheen: Double
    var edgeTop: Double
    var edgeBottom: Double
    var shadowRadius: Double
    var shadowOpacity: Double
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode

    /// Raised surfaces: cards, rows, banners.
    static let panel = GlassStyle(
        tint: nil, tintOpacity: 0.09, sheen: 0.45,
        edgeTop: 0.32, edgeBottom: 0.09,
        shadowRadius: 9, shadowOpacity: 0.20,
        material: .hudWindow, blending: .withinWindow
    )

    /// Interactive surfaces: buttons, tabs, menus.
    static let control = GlassStyle(
        tint: nil, tintOpacity: 0.13, sheen: 0.72,
        edgeTop: 0.46, edgeBottom: 0.11,
        shadowRadius: 6, shadowOpacity: 0.24,
        material: .hudWindow, blending: .withinWindow
    )

    /// Sunken surfaces: the script editor, the output console. Quieter and
    /// darker so monospaced text stays crisp instead of fighting the sheen.
    static let recessed = GlassStyle(
        tint: .black, tintOpacity: 0.20, sheen: 0.10,
        edgeTop: 0.13, edgeBottom: 0.05,
        shadowRadius: 0, shadowOpacity: 0,
        material: .contentBackground, blending: .withinWindow
    )

    /// The window slab itself — blurs the desktop behind the app.
    static let window = GlassStyle(
        tint: nil, tintOpacity: 0.05, sheen: 0.30,
        edgeTop: 0, edgeBottom: 0,
        shadowRadius: 0, shadowOpacity: 0,
        material: .hudWindow, blending: .behindWindow
    )

    func tinted(_ color: Color, opacity: Double = 0.32) -> GlassStyle {
        var copy = self
        copy.tint = color
        copy.tintOpacity = opacity
        return copy
    }

    func amplified(_ factor: Double) -> GlassStyle {
        var copy = self
        copy.sheen *= factor
        copy.tintOpacity *= (1 + (factor - 1) * 0.6)
        return copy
    }
}

// MARK: - The glass itself

/// Four stacked layers make the pane read as glass:
/// blurred backdrop → colored body → specular sheen → lit rim.
struct GlassSurface<S: InsettableShape>: View {
    var shape: S
    var style: GlassStyle = .control
    var isPressed: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.glassIntensity) private var intensity

    var body: some View {
        let isDark = scheme == .dark
        let strength = min(max(intensity, 0.2), 1.8)
        let tint = style.tint ?? (isDark ? Color.white : Color.white)
        let tintOpacity = style.tintOpacity * strength * (isPressed ? 1.5 : 1) * (isDark ? 1.0 : 1.2)
        let sheen = style.sheen * strength * (isPressed ? 0.55 : 1) * (isDark ? 1.0 : 0.85)

        ZStack {
            BackdropBlur(material: style.material, blending: style.blending)
                .clipShape(shape)

            // Body: the color actually suspended in the pane.
            shape.fill(
                LinearGradient(
                    colors: [tint.opacity(tintOpacity), tint.opacity(tintOpacity * 0.42)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Sheen: bright at the top where light enters, a faint bounce
            // back up from the bottom edge.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.50 * sheen), location: 0.0),
                        .init(color: .white.opacity(0.10 * sheen), location: 0.30),
                        .init(color: .clear, location: 0.62),
                        .init(color: .white.opacity(0.13 * sheen), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .blendMode(.plusLighter)

            // Rim: a hairline that catches light on top and grounds the
            // shape on the bottom.
            shape.strokeBorder(
                LinearGradient(
                    colors: isDark
                        ? [.white.opacity(style.edgeTop),
                           .white.opacity(style.edgeBottom * 0.7),
                           .white.opacity(style.edgeBottom)]
                        : [.white.opacity(min(style.edgeTop * 1.5, 0.9)),
                           .white.opacity(style.edgeBottom * 0.5),
                           .black.opacity(style.edgeBottom * 0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .compositingGroup()
        .shadow(
            color: .black.opacity(style.shadowOpacity),
            radius: style.shadowRadius,
            x: 0,
            y: style.shadowRadius * 0.35
        )
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S, style: GlassStyle = .control, isPressed: Bool = false) -> some View {
        background(GlassSurface(shape: shape, style: style, isPressed: isPressed))
    }
}

// MARK: - Buttons
//
// Every button carries its own independent pane — nothing is merged into a
// shared container, so each one reads as a separate piece of glass.

struct GlassButtonStyle: ButtonStyle {
    var tint: Color?
    var capsuleShape: Bool = false
    var cornerRadius: CGFloat = 10
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 7
    var fullWidth: Bool = false
    var font: Font = .system(size: 12.5, weight: .medium)

    func makeBody(configuration: Configuration) -> some View {
        GlassButtonBody(configuration: configuration, style: self)
    }
}

private struct GlassButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let style: GlassButtonStyle

    @State private var isHovering = false

    private var glass: GlassStyle {
        var base = GlassStyle.control
        if let tint = style.tint { base = base.tinted(tint) }
        if isHovering { base = base.amplified(1.3) }
        return base
    }

    private var label: some View {
        configuration.label
            .font(style.font)
            .foregroundStyle(style.tint == nil ? Color.primary : Color.white)
            .shadow(color: .black.opacity(style.tint == nil ? 0 : 0.3), radius: 1, y: 0.5)
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .frame(maxWidth: style.fullWidth ? .infinity : nil)
    }

    var body: some View {
        Group {
            if style.capsuleShape {
                label.glass(Capsule(), style: glass, isPressed: configuration.isPressed)
            } else {
                label.glass(
                    RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous),
                    style: glass,
                    isPressed: configuration.isPressed
                )
            }
        }
        .scaleEffect(configuration.isPressed ? 0.975 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

struct GlassIconButtonStyle: ButtonStyle {
    var tint: Color?
    var size: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        GlassIconButtonBody(configuration: configuration, style: self)
    }
}

private struct GlassIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let style: GlassIconButtonStyle

    @State private var isHovering = false

    private var glass: GlassStyle {
        var base = GlassStyle.control
        if let tint = style.tint { base = base.tinted(tint) }
        if isHovering { base = base.amplified(1.3) }
        return base
    }

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(style.tint == nil ? Color.secondary : Color.white)
            .frame(width: style.size, height: style.size)
            .glass(Circle(), style: glass, isPressed: configuration.isPressed)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static func glass(
        tint: Color? = nil,
        capsule: Bool = false,
        cornerRadius: CGFloat = 10,
        fullWidth: Bool = false,
        horizontalPadding: CGFloat = 14
    ) -> GlassButtonStyle {
        GlassButtonStyle(
            tint: tint,
            capsuleShape: capsule,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            fullWidth: fullWidth
        )
    }
}

extension ButtonStyle where Self == GlassIconButtonStyle {
    static func glassIcon(tint: Color? = nil, size: CGFloat = 26) -> GlassIconButtonStyle {
        GlassIconButtonStyle(tint: tint, size: size)
    }
}

// MARK: - Window chrome

/// Makes the window frameless-feeling: transparent background, hidden
/// title, optionally floating above other apps — while keeping the one
/// thing a frameless window usually loses, which is the ability to become
/// the key window and receive typing.
struct WindowConfigurator: NSViewRepresentable {
    var floatOnTop: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var didClaimFocus = false
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window, coordinator: context.coordinator)
        }
    }

    private func configure(_ window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }

        // `.titled` is what makes `canBecomeKey` true. A window that loses
        // it — which is what a fully borderless "frameless" window is —
        // can never take keyboard focus, no matter what the views inside it
        // do. The title bar is hidden rather than removed.
        if !window.styleMask.contains(.titled) {
            window.styleMask.insert(.titled)
        }
        window.styleMask.insert([.closable, .miniaturizable, .resizable, .fullSizeContentView])

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // Drag-anywhere is off: AppKit asks each view whether a click there
        // should move the window, and views that don't paint their own
        // background (everything on glass) say yes — which swallowed clicks
        // meant for the editor and text fields. The window still drags from
        // the title bar strip at the top.
        window.isMovableByWindowBackground = false

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = floatOnTop ? .floating : .normal

        // Once, on first appearance — repeating this on every SwiftUI
        // update would yank focus back out of sheets and menus.
        if !coordinator.didClaimFocus {
            coordinator.didClaimFocus = true
            window.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Glass intensity

private struct GlassIntensityKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    /// Multiplies sheen and tint across every glass surface, so the
    /// Appearance setting can dial the whole app up or down at once.
    var glassIntensity: Double {
        get { self[GlassIntensityKey.self] }
        set { self[GlassIntensityKey.self] = newValue }
    }
}
