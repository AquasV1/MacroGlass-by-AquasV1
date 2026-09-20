import SwiftUI
import AppKit

/// Every step of a recording, in order, with the time it fires at — and
/// editable, because the usual reason to open this is that one stray click
/// or one long pause is ruining an otherwise good macro.
struct MacroInspectorSheet: View {
    let tint: Color
    var onSave: (Macro) -> Void
    var onClose: () -> Void

    @State private var draft: Macro
    @State private var showsMoves = true
    @State private var selected: UUID?

    init(macro: Macro, tint: Color, onSave: @escaping (Macro) -> Void, onClose: @escaping () -> Void) {
        self.tint = tint
        self.onSave = onSave
        self.onClose = onClose
        _draft = State(initialValue: macro)
    }

    private var steps: [(index: Int, event: MacroEvent)] {
        draft.events.enumerated()
            .filter { showsMoves || $0.element.type != .mouseMoved }
            .map { (index: $0.offset + 1, event: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            controls

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(steps, id: \.event.id) { step in
                        row(index: step.index, event: step.event)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .frame(height: 260)
            .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .recessed)

            notesField

            HStack(spacing: 8) {
                Button("Copy as text") { copyTranscript() }
                    .buttonStyle(.glass(capsule: true))
                Button("Cancel", action: onClose)
                    .buttonStyle(.glass(capsule: true))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save changes") { onSave(draft) }
                    .buttonStyle(.glass(tint: tint, capsule: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(GlassSurface(shape: Rectangle(), style: .window))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(draft.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(draft.events.count) steps · \(String(format: "%.1fs", draft.duration)) · \(draft.breakdown)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if let hotkey = draft.hotkey {
                Text("Triggered by \(hotkey.displayName)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if draft.moveCount > 0 {
                Toggle("Show moves", isOn: $showsMoves)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 11.5))

                Button("Drop all moves") {
                    draft.events.removeAll { $0.type == .mouseMoved }
                }
                .buttonStyle(.glass(capsule: true))
            }
            Spacer()
            Button("Trim pauses") {
                draft = draft.trimmed(maxGap: 2)
            }
            .buttonStyle(.glass(capsule: true))
            .help("Squeeze every gap down to two seconds")
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("NOTES")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            TextField("What this is for, which window it expects…", text: Binding(
                get: { draft.notes ?? "" },
                set: { draft.notes = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glass(RoundedRectangle(cornerRadius: 9, style: .continuous), style: .recessed)
        }
    }

    private func row(index: Int, event: MacroEvent) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)

            Image(systemName: event.symbol)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(event.summary)
                .font(.system(size: 11.5))
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(String(format: "%.2fs", event.timestamp))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Menu {
                Button("Delete this step") { delete(event) }
                Divider()
                Button("Pause ½s after this") { insertPause(0.5, after: event) }
                Button("Pause 1s after this") { insertPause(1, after: event) }
                Button("Pause 3s after this") { insertPause(3, after: event) }
                Divider()
                Button("Delete everything before this") { deleteBefore(event) }
                Button("Delete everything after this") { deleteAfter(event) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20, height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(selected == event.id ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { selected = (selected == event.id) ? nil : event.id }
    }

    // MARK: Editing

    /// Removing a step closes the gap it occupied, otherwise deleting a
    /// stray click leaves a mysterious pause exactly where it used to be.
    private func delete(_ event: MacroEvent) {
        guard let index = draft.events.firstIndex(where: { $0.id == event.id }) else { return }
        let previous = index > 0 ? draft.events[index - 1].timestamp : 0
        let gap = max(0, event.timestamp - previous)

        draft.events.remove(at: index)
        for i in index..<draft.events.count {
            draft.events[i].timestamp = max(0, draft.events[i].timestamp - gap)
        }
    }

    private func insertPause(_ seconds: TimeInterval, after event: MacroEvent) {
        guard let index = draft.events.firstIndex(where: { $0.id == event.id }) else { return }
        for i in (index + 1)..<draft.events.count {
            draft.events[i].timestamp += seconds
        }
    }

    private func deleteBefore(_ event: MacroEvent) {
        guard let index = draft.events.firstIndex(where: { $0.id == event.id }), index > 0 else { return }
        draft.events.removeFirst(index)
        draft = draft.trimmed()
    }

    private func deleteAfter(_ event: MacroEvent) {
        guard let index = draft.events.firstIndex(where: { $0.id == event.id }) else { return }
        draft.events.removeLast(draft.events.count - index - 1)
    }

    private func copyTranscript() {
        let lines = draft.events.enumerated().map { index, event in
            String(format: "%4d  %7.2fs  %@", index + 1, event.timestamp, event.summary)
        }
        let text = (["\(draft.name) — \(draft.events.count) steps"] + lines).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
