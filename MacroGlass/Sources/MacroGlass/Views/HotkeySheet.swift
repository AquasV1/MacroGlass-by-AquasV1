import SwiftUI

/// Press the combination you want. The recorder consumes the keystroke, so
/// nothing else in the app reacts to it while you're choosing. Shared by
/// the Record tab (per-macro triggers) and Settings (panic stop, record
/// start/stop).
struct HotkeySheet: View {
    let title: String
    let current: MacroHotkey?
    let tint: Color
    var conflictCheck: (MacroHotkey) -> String?
    var onSave: (MacroHotkey?) -> Void
    var onCancel: () -> Void

    @StateObject private var recorder = HotkeyRecorder()
    @State private var chosen: MacroHotkey?

    private var conflict: String? {
        guard let chosen, chosen != current else { return nil }
        return conflictCheck(chosen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            Button {
                recorder.begin()
            } label: {
                Text(fieldLabel)
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
            }
            .buttonStyle(.glass(tint: recorder.isCapturing ? tint : nil, cornerRadius: 11, fullWidth: true))

            if let conflict {
                Text("That combination is already used for \(conflict).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Hotkeys work anywhere on the Mac, and are swallowed so the app in front doesn't also see them. Esc backs out.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    recorder.cancel()
                    onCancel()
                }
                .buttonStyle(.glass(capsule: true))
                .keyboardShortcut(.cancelAction)

                if current != nil || chosen != nil {
                    Button("Clear") {
                        recorder.cancel()
                        onSave(nil)
                    }
                    .buttonStyle(.glass(capsule: true))
                }

                Spacer()

                Button("Assign") {
                    recorder.cancel()
                    onSave(chosen)
                }
                .buttonStyle(.glass(tint: tint, capsule: true))
                .disabled(chosen == nil || conflict != nil)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(GlassSurface(shape: Rectangle(), style: .window))
        .onAppear { chosen = current }
        .onChange(of: recorder.captured) { _, captured in
            if let captured { chosen = captured }
        }
    }

    private var fieldLabel: String {
        if recorder.isCapturing { return "Press a combination…" }
        if let chosen { return chosen.displayName }
        return "Click, then press a combination"
    }
}
