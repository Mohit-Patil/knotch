import AppKit
import SwiftUI

/// A compact history strip that can share the panel with a live terminal.
struct ClipboardShelfView: View {
    @ObservedObject var history: ClipboardHistory
    let canInsert: Bool
    let onInsert: (UUID) -> Void
    let onOpenLibrary: () -> Void
    let onHide: () -> Void
    let onDragChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if history.entries.isEmpty {
                emptyState
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(history.entries) { entry in
                            ClipboardShelfCard(
                                entry: entry,
                                canInsert: canInsert,
                                onCopy: { history.copy(entry) },
                                onInsert: { onInsert(entry.id) },
                                onDragChange: onDragChange
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .accessibilityLabel("Clipboard history items")
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.105, green: 0.111, blue: 0.124))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Clipboard")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text("\(history.entries.count)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))

            if history.isPaused {
                Text("Paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))
                    .accessibilityLabel("Clipboard capture paused")
            }

            Spacer(minLength: 0)

            Button(action: onOpenLibrary) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 10, weight: .medium))
                    Text("History")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.68))
            }
            .buttonStyle(.plain)
            .help("Open clipboard history")
            .accessibilityLabel("Open clipboard history")

            Button(action: onHide) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.56))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide clipboard shelf")
            .accessibilityLabel("Hide clipboard shelf")
        }
        .padding(.horizontal, 12)
        .frame(height: 20)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: history.isPaused ? "pause.circle" : "clipboard")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(.white.opacity(0.43))
            Text(history.isPaused ? "Capture is paused" : "Copied items appear here")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.52))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 26)
        .accessibilityElement(children: .combine)
    }
}

private struct ClipboardShelfCard: View {
    let entry: ClipboardEntry
    let canInsert: Bool
    let onCopy: () -> Void
    let onInsert: () -> Void
    let onDragChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isDragging = false
    @FocusState private var cardFocused: Bool
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable { case copy, insert }

    private var showsImageActions: Bool {
        !isDragging && (isHovered || cardFocused || focusedAction != nil)
    }

    // Decode at most once for each card construction, including image cards.
    private let previewImage: NSImage?

    init(entry: ClipboardEntry, canInsert: Bool, onCopy: @escaping () -> Void,
         onInsert: @escaping () -> Void,
         onDragChange: @escaping (Bool) -> Void) {
        self.entry = entry
        self.canInsert = canInsert
        self.onCopy = onCopy
        self.onInsert = onInsert
        self.onDragChange = onDragChange
        previewImage = entry.kind == .image ? entry.data.flatMap(NSImage.init(data:)) : nil
    }

    var body: some View {
        Group {
            if let previewImage {
                imageCard(previewImage)
            } else {
                contentCard
            }
        }
        .frame(width: 174, height: 110)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(.white.opacity(0.075), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func imageCard(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 166, height: 102)
            .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .overlay(ClipboardDragSource(entry: entry, onDragChange: { dragging in
                isDragging = dragging
                onDragChange(dragging)
            }, onHoverChange: { isHovered = $0 }))
            .overlay(alignment: .topTrailing) {
                if entry.pinned { pinBadge.allowsHitTesting(false) }
            }
            .overlay(alignment: .bottomTrailing) {
                imageActions
                    .padding(5)
                    .opacity(showsImageActions ? 1 : 0)
                    .allowsHitTesting(showsImageActions)
                    .accessibilityHidden(!showsImageActions)
            }
            .padding(4)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .focusable(interactions: .activate)
            .focused($cardFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard cardFocused && focusedAction == nil else { return .ignored }
                onCopy()
                return .handled
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsImageActions)
            .help("Drag into the terminal or onto another terminal tab")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Image: \(accessibleSummary). Drag into terminal.")
            .accessibilityActions {
                Button("Copy image to clipboard", action: onCopy)
                if canInsert {
                    Button("Insert image into terminal", action: onInsert)
                }
            }
    }

    private var imageActions: some View {
        HStack(spacing: 4) {
            actionButton("Copy", symbol: "doc.on.doc", action: onCopy)
                .focused($focusedAction, equals: .copy)
                .accessibilityLabel("Copy \(accessibleSummary) to clipboard")
            if canInsert {
                actionButton("Insert", symbol: "arrow.up.to.line", action: onInsert)
                    .focused($focusedAction, equals: .insert)
                    .accessibilityLabel("Insert \(accessibleSummary) into terminal")
                    .help("Insert into the selected terminal without pressing Return")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(3)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 7))
    }

    private var contentCard: some View {
        VStack(spacing: 6) {
            preview
                .frame(width: 158, height: 62)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(ClipboardDragSource(entry: entry, onDragChange: onDragChange))
                .help("Drag into the terminal or onto another terminal tab")
                .accessibilityLabel("\(kindName): \(accessibleSummary). Drag into terminal.")

            HStack(spacing: 5) {
                actionButton("Copy", symbol: "doc.on.doc", action: onCopy)
                    .accessibilityLabel("Copy \(accessibleSummary) to clipboard")
                if canInsert {
                    actionButton("Insert", symbol: "arrow.up.to.line", action: onInsert)
                        .accessibilityLabel("Insert \(accessibleSummary) into terminal")
                        .help("Insert into the selected terminal without pressing Return")
                }
            }
            .frame(height: 22)
        }
        .padding(8)
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if entry.pinned { pinBadge }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: kindSymbol)
                        .font(.system(size: 10, weight: .medium))
                    Text(kindName)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                    if entry.pinned { pinBadge }
                }
                .foregroundStyle(.white.opacity(0.49))

                Text(entry.label.isEmpty ? "Untitled item" : entry.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(7)
        }
    }

    private var pinBadge: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.64))
            .padding(4)
            .accessibilityLabel("Pinned")
    }

    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(red: 0.52, green: 0.69, blue: 0.91))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(.white.opacity(0.055), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var accessibleSummary: String {
        let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? kindName.lowercased() : String(label.prefix(80))
    }

    private var kindName: String {
        switch entry.kind {
        case .text: "Text"
        case .link: "Link"
        case .richText: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
    }

    private var kindSymbol: String {
        switch entry.kind {
        case .text: "text.alignleft"
        case .link: "link"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}
