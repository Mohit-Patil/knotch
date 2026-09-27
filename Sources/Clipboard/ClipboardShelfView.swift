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
                                onCopy: { Task { await history.copy(entry) } },
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

    private var showsActions: Bool {
        !isDragging && (isHovered || cardFocused || focusedAction != nil)
    }

    var body: some View {
        preview
            .frame(width: 166, height: 102)
            .background(Color.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .clipped()
            .overlay(ClipboardDragSource(entry: entry, onDragChange: { dragging in
                isDragging = dragging
                onDragChange(dragging)
            }, onHoverChange: { isHovered = $0 }))
            .overlay(alignment: .topTrailing) {
                if entry.pinned { pinBadge.allowsHitTesting(false) }
            }
            .overlay(alignment: .bottomTrailing) {
                cardActions
                    .padding(5)
                    .opacity(showsActions ? 1 : 0)
                    .allowsHitTesting(showsActions)
                    .accessibilityHidden(!showsActions)
            }
            .padding(4)
            .frame(width: 174, height: 110)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.075), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .focusable(interactions: .activate)
            .focused($cardFocused)
            .focusEffectDisabled()
            .onKeyPress(.space) {
                guard cardFocused && focusedAction == nil else { return .ignored }
                onCopy()
                return .handled
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsActions)
            .help("Drag into the terminal or onto another terminal tab")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(kindName): \(accessibleSummary). Drag into terminal.")
            .accessibilityActions {
                Button("Copy \(kindName.lowercased()) to clipboard", action: onCopy)
                if canInsert {
                    Button("Insert \(kindName.lowercased()) into terminal", action: onInsert)
                }
            }
    }

    private var cardActions: some View {
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

    @ViewBuilder
    private var preview: some View {
        if entry.kind == .image {
            ClipboardThumbnail(entry: entry)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: kindSymbol)
                        .font(.system(size: 10, weight: .medium))
                    Text(previewHeading)
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white.opacity(0.49))

                Text(verbatim: previewText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(8)
        }
    }

    private var previewHeading: String {
        if entry.kind == .files, let count = entry.fileURLs?.count, count > 1 {
            return "\(count) files"
        }
        return kindName
    }

    private var previewText: String {
        if entry.kind == .files, let urls = entry.fileURLs, !urls.isEmpty {
            var names = urls.prefix(3).map(\.lastPathComponent)
            if urls.count > 3 { names.append("+\(urls.count - 3) more") }
            return names.joined(separator: "\n")
        }
        let text = entry.text ?? entry.textPreview ?? entry.label
        return text.isEmpty ? "Untitled item" : String(text.prefix(640))
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
