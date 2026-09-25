import AppKit
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let onDragChange: (Bool) -> Void
    @State private var query = ""
    @State private var confirmClearAll = false
    @State private var focusedImageID: UUID?

    private var visible: [ClipboardEntry] {
        let ordered = history.entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt > $1.createdAt
        }
        guard !query.isEmpty else { return ordered }
        return ordered.filter { $0.label.localizedCaseInsensitiveContains(query) }
    }

    private var imageEntries: [ClipboardEntry] {
        visible.filter { $0.kind == .image && $0.data.flatMap(NSImage.init(data:)) != nil }
    }

    private var otherEntries: [ClipboardEntry] {
        visible.filter { entry in !imageEntries.contains(where: { $0.id == entry.id }) }
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !imageEntries.isEmpty {
                            imageCarousel
                        }
                        LazyVStack(spacing: 8) {
                            ForEach(otherEntries) { entry in
                                compactRow(entry)
                            }
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

    private var imageCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Images")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(imageEntries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { advanceImage(by: -1) } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(imageEntries.first?.id == focusedImageID || imageEntries.count < 2)
                .accessibilityLabel("Previous image")
                Button { advanceImage(by: 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(imageEntries.last?.id == focusedImageID || imageEntries.count < 2)
                .accessibilityLabel("Next image")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 2)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(imageEntries) { entry in
                        if let data = entry.data, let image = NSImage(data: data) {
                            imageTile(entry, image: image)
                                .id(entry.id)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedImageID)
            .onAppear { reconcileFocusedImage() }
            .onChange(of: imageEntries.map(\.id)) { oldIDs, newIDs in
                if let added = newIDs.first(where: { !oldIDs.contains($0) }) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        focusedImageID = added
                    }
                } else {
                    reconcileFocusedImage()
                }
            }
        }
    }

    private func advanceImage(by offset: Int) {
        let entries = imageEntries
        guard let index = entries.firstIndex(where: { $0.id == focusedImageID }),
              entries.indices.contains(index + offset) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
            focusedImageID = entries[index + offset].id
        }
    }

    private func reconcileFocusedImage() {
        guard !imageEntries.isEmpty else { focusedImageID = nil; return }
        if !imageEntries.contains(where: { $0.id == focusedImageID }) {
            focusedImageID = imageEntries.first?.id
        }
    }

    private func imageTile(_ entry: ClipboardEntry, image: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 210, height: 130)
                .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(ClipboardDragSource(entry: entry, onDragChange: onDragChange))
                .help("Drag image to a terminal tab")
                .accessibilityLabel("Image preview")
            HStack(spacing: 4) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                actions(for: entry)
            }
        }
        .padding(8)
        .frame(width: 226)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func compactRow(_ entry: ClipboardEntry) -> some View {
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
            actions(for: entry)
        }
        .padding(10)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actions(for entry: ClipboardEntry) -> some View {
        HStack(spacing: 10) {
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
