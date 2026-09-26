import AppKit
import SwiftUI

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let onDragChange: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var confirmClearAll = false
    @State private var focusedImageID: UUID?
    @State private var selectedFilter: Filter = .all

    private enum Filter: String, CaseIterable {
        case all = "All"
        case images = "Images"
        case text = "Text"
        case files = "Files"
        case pinned = "Pinned"

        func includes(_ entry: ClipboardEntry) -> Bool {
            switch self {
            case .all: true
            case .images: entry.kind == .image
            case .text: entry.kind == .text || entry.kind == .link || entry.kind == .richText
            case .files: entry.kind == .files
            case .pinned: entry.pinned
            }
        }

        var emptyTitle: String {
            switch self {
            case .all: "No clipboard items"
            case .images: "No images"
            case .text: "No text items"
            case .files: "No files"
            case .pinned: "No pinned items"
            }
        }

        var symbol: String {
            switch self {
            case .all: "clipboard"
            case .images: "photo"
            case .text: "text.alignleft"
            case .files: "doc.on.doc"
            case .pinned: "pin"
            }
        }
    }

    private let panelColor = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let accentColor = Color(red: 0.52, green: 0.69, blue: 0.91)

    private var visible: [ClipboardEntry] {
        let ordered = history.entries.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt > $1.createdAt
        }
        return ordered.filter { entry in
            selectedFilter.includes(entry)
                && (query.isEmpty || entry.label.localizedCaseInsensitiveContains(query))
        }
    }

    private var imageEntries: [ClipboardEntry] {
        visible.filter { $0.kind == .image }
    }

    private var otherEntries: [ClipboardEntry] {
        visible.filter { $0.kind != .image }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.48))
                TextField("Search clipboard history", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .accessibilityLabel("Search clipboard history")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                Button {
                    history.setPaused(!history.isPaused)
                } label: {
                    Label(history.isPaused ? "Resume" : "Pause",
                          systemImage: history.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
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
            .padding(10)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            filters

            if visible.isEmpty {
                ContentUnavailableView(emptyTitle,
                                       systemImage: history.isPaused && history.entries.isEmpty
                                           ? "pause.circle" : selectedFilter.symbol,
                                       description: Text(emptyDescription))
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
        .background(panelColor)
        .preferredColorScheme(.dark)
        .confirmationDialog("Clear all clipboard history?", isPresented: $confirmClearAll) {
            Button("Clear all history", role: .destructive) { history.clearAll() }
        } message: {
            Text("This removes pinned items too. It does not change the current clipboard.")
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Filter.allCases, id: \.self) { filter in
                    let selected = selectedFilter == filter
                    Button { selectedFilter = filter } label: {
                        HStack(spacing: 5) {
                            Text(filter.rawValue)
                            Text("\(history.entries.filter { filter.includes($0) }.count)")
                                .foregroundStyle(selected ? accentColor : .white.opacity(0.45))
                        }
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .white : .white.opacity(0.68))
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(selected ? accentColor.opacity(0.15) : .white.opacity(0.045),
                                    in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(selected ? accentColor.opacity(0.32)
                                                            : .white.opacity(0.065), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(filter.rawValue), \(history.entries.filter { filter.includes($0) }.count) items")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
        .frame(height: 25)
        .accessibilityLabel("Clipboard filters")
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "No matching items" }
        if history.entries.isEmpty && history.isPaused { return "Capture paused" }
        return selectedFilter.emptyTitle
    }

    private var emptyDescription: String {
        if !query.isEmpty { return "No items match your search in \(selectedFilter.rawValue.lowercased())." }
        if history.entries.isEmpty && history.isPaused { return "Resume capture to save new items." }
        if selectedFilter == .all { return "Copy text, an image, or files to see them here." }
        return "Items in this filter appear here."
    }

    private var imageCarousel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Images")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.87))
                Text("\(imageEntries.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.47))
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
                        imageTile(entry, image: entry.data.flatMap(NSImage.init(data:)))
                            .id(entry.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedImageID)
            .onAppear { reconcileFocusedImage() }
            .onChange(of: imageEntries.map(\.id)) { oldIDs, newIDs in
                let previousIDs = Set(oldIDs)
                if let added = newIDs.first(where: { !previousIDs.contains($0) }) {
                    setFocusedImage(added)
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
        setFocusedImage(entries[index + offset].id)
    }

    private func setFocusedImage(_ id: UUID) {
        if reduceMotion {
            focusedImageID = id
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                focusedImageID = id
            }
        }
    }

    private func reconcileFocusedImage() {
        guard !imageEntries.isEmpty else { focusedImageID = nil; return }
        if !imageEntries.contains(where: { $0.id == focusedImageID }) {
            focusedImageID = imageEntries.first?.id
        }
    }

    private func imageTile(_ entry: ClipboardEntry, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .frame(width: 210, height: 130)
            .background(.black.opacity(0.19), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(ClipboardDragSource(entry: entry, onDragChange: onDragChange))
            .help("Drag image to a terminal tab")
            .accessibilityLabel("Image preview")
            HStack(spacing: 4) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.49))
                Spacer(minLength: 0)
                actions(for: entry)
            }
        }
        .padding(8)
        .frame(width: 226)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func compactRow(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 12) {
            thumbnail(entry)
                .frame(width: 64, height: 58)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                .overlay(ClipboardDragSource(entry: entry, onDragChange: onDragChange))
                .help("Drag to a terminal tab")
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.label)
                    .lineLimit(2)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.88))
                    .textSelection(.enabled)
                Text(detail(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions(for: entry)
        }
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private func actions(for entry: ClipboardEntry) -> some View {
        HStack(spacing: 10) {
            Button { history.copy(entry) } label: {
                Text("Copy")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.white.opacity(0.07), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(String(entry.label.prefix(80))) back to clipboard")
            Button {
                history.togglePinned(entry.id)
            } label: {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(.white.opacity(0.66))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.pinned ? "Unpin item" : "Pin item")
            Button {
                history.remove(entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.white.opacity(0.55))
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
                .foregroundStyle(.white.opacity(0.51))
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
