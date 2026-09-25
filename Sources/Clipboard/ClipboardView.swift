import AppKit
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let onDragChange: (Bool) -> Void
    @State private var query = ""
    @State private var confirmClearAll = false

    private var visible: [ClipboardEntry] {
        let ordered = history.entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt > $1.createdAt
        }
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search clipboard history")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
                Button {
                    history.setPaused(!history.isPaused)
                } label: {
                    Label(history.isPaused ? "Resume" : "Pause",
                          systemImage: history.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(history.isPaused ? "Resume clipboard capture" : "Pause clipboard capture")
                Menu {
                    Button("Clear unpinned history") { history.clearUnpinned() }
                    Button("Clear all history…", role: .destructive) { confirmClearAll = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
                .accessibilityLabel("Clipboard options")
            }
            .padding(12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 10))

            if visible.isEmpty {
                ContentUnavailableView(history.isPaused ? "Capture paused" : "No clipboard items",
                                       systemImage: history.isPaused ? "pause.circle" : "clipboard",
                                       description: Text(query.isEmpty
                                                         ? "Copy text, an image, or files in any app to see them here."
                                                         : "No items match your search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Drag an item onto a terminal tab", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { entry in
                            row(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .confirmationDialog("Clear all clipboard history?", isPresented: $confirmClearAll) {
            Button("Clear all history", role: .destructive) { history.clearAll() }
        } message: {
            Text("This removes pinned items too. It does not change the current clipboard.")
        }
    }

    @ViewBuilder
    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry)
                .frame(width: 64, height: 58)
                .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(ClipboardDragSource(entry: entry, onDragChange: onDragChange))
                .help("Drag to a terminal tab")
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.label)
                    .lineLimit(2)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") { history.copy(entry) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Copy \(entry.label) back to clipboard")
            Button {
                history.togglePinned(entry.id)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.pinned ? "Unpin item" : "Pin item")
            Button {
                history.remove(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove item")
        }
        .padding(10)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func thumbnail(_ entry: ClipboardEntry) -> some View {
        if entry.kind == .image, let data = entry.data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: symbol(entry.kind))
                .font(.system(size: 23, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private func symbol(_ kind: ClipboardEntry.Kind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    private func detail(_ entry: ClipboardEntry) -> String {
        let kind: String = switch entry.kind {
        case .text: "Text"
        case .link: "Link"
        case .richText: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
        return "\(kind) · \(entry.createdAt.formatted(date: .omitted, time: .shortened))"
    }
}
