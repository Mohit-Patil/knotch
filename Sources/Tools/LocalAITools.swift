import AppKit
import FoundationModels
import Observation
import SwiftUI

/// In-memory conversation state. The owner should retain this store while tabs change.
@MainActor @Observable
final class LocalAIToolsStore {
    struct Message: Identifiable {
        enum Role { case user, assistant }

        let id: UUID
        let role: Role
        var text: String

        init(role: Role, text: String) {
            id = UUID()
            self.role = role
            self.text = text
        }
    }

    var draft = ""
    private(set) var messages: [Message] = []
    private(set) var isGenerating = false
    private(set) var conversationEnded = false
    private(set) var notice: String?
    private(set) var availability: SystemLanguageModel.Availability

    private let model = SystemLanguageModel.default
    private var session: LanguageModelSession?
    private var requestTask: Task<Void, Never>?
    private var activeRequestID: UUID?

    init() {
        availability = model.availability
    }

    var availabilityMessage: String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "On-device AI isn't available on this Mac or in this region."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to use on-device AI."
        case .unavailable(.modelNotReady):
            return "The Apple Intelligence model isn't ready yet. It may still be downloading. Try again later."
        case .unavailable:
            return "On-device AI is unavailable right now."
        }
    }

    var canSend: Bool {
        availabilityMessage == nil && !conversationEnded && !isGenerating
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshAvailability() {
        availability = model.availability
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isGenerating, !conversationEnded else { return }
        refreshAvailability()
        guard availabilityMessage == nil else { return }

        draft = ""
        notice = nil
        messages.append(Message(role: .user, text: prompt))
        let replyID = UUID()
        messages.append(Message(role: .assistant, text: ""))
        // Keep the session only for this conversation. No tools are supplied,
        // so generated text cannot execute shell commands or access app data.
        if session == nil {
            session = LanguageModelSession(model: model, tools: [], instructions: "Reply to the user's text. You have no tools and cannot run commands, read files, or access the network. Be clear when you do not know something.")
        }
        guard let session else { return }

        activeRequestID = replyID
        isGenerating = true
        requestTask = Task { @MainActor [weak self] in
            do {
                for try await snapshot in session.streamResponse(to: prompt) {
                    guard let self, self.activeRequestID == replyID else { return }
                    self.updateReply(snapshot.content)
                }
                guard let self, self.activeRequestID == replyID else { return }
                if self.messages.last?.text.isEmpty == true {
                    self.updateReply("The model returned an empty response. Try again.")
                }
                self.finishRequest()
            } catch is CancellationError {
                // cancel() or shutdown() already updated the visible state.
            } catch {
                guard let self, self.activeRequestID == replyID else { return }
                self.handle(error)
                self.finishRequest()
            }
        }
    }

    func cancel() {
        guard isGenerating else { return }
        activeRequestID = nil
        requestTask?.cancel()
        requestTask = nil
        session = nil
        isGenerating = false
        conversationEnded = true
        if messages.last?.role == .assistant && messages.last?.text.isEmpty == true {
            messages.removeLast()
        }
        notice = "Response stopped. Start a new conversation to continue."
    }

    func newConversation() {
        activeRequestID = nil
        requestTask?.cancel()
        requestTask = nil
        session = nil
        messages.removeAll()
        draft = ""
        notice = nil
        isGenerating = false
        conversationEnded = false
        refreshAvailability()
    }

    func shutdown() {
        activeRequestID = nil
        requestTask?.cancel()
        requestTask = nil
        session = nil
        messages.removeAll()
        draft = ""
        notice = nil
        isGenerating = false
        conversationEnded = false
    }

    private func updateReply(_ content: String) {
        guard messages.last?.role == .assistant else { return }
        messages[messages.count - 1].text = content
    }

    private func finishRequest() {
        activeRequestID = nil
        requestTask = nil
        isGenerating = false
    }

    private func handle(_ error: Error) {
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize:
                endConversation("This conversation has reached the model's context limit. Start a new conversation to continue.")
                return
            case .assetsUnavailable:
                refreshAvailability()
                showError("The on-device model isn't ready yet. Try again later.")
                return
            default:
                break
            }
        }
        if #available(macOS 27, *), let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded:
                endConversation("This conversation has reached the model's context limit. Start a new conversation to continue.")
                return
            default:
                break
            }
        }
        refreshAvailability()
        if let availabilityMessage {
            showError(availabilityMessage)
        } else {
            showError("The on-device model couldn't answer. Please try again.")
        }
    }

    private func endConversation(_ message: String) {
        session = nil
        conversationEnded = true
        showError(message)
    }

    private func showError(_ message: String) {
        if messages.last?.role == .assistant && messages.last?.text.isEmpty == true {
            messages.removeLast()
        }
        notice = message
    }
}

struct LocalAIToolsView: View {
    @Bindable var store: LocalAIToolsStore
    @FocusState private var composerFocused: Bool

    private let panelColor = Color(red: 0.105, green: 0.111, blue: 0.124)
    private let accentColor = Color(red: 0.52, green: 0.69, blue: 0.91)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.08))
            conversation
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelColor)
        .preferredColorScheme(.dark)
        .onAppear { store.refreshAvailability() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("On-device AI")
                    .font(.system(size: 14, weight: .semibold))
                Text("Apple Intelligence · This conversation stays in memory")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.newConversation()
                composerFocused = true
            } label: {
                Label("New conversation", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("Clear this conversation and start over")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.messages.isEmpty {
                        ContentUnavailableView("Ask anything",
                                               systemImage: "sparkles",
                                               description: Text("Write a question below to use the on-device model."))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    ForEach(store.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }
                    if let message = store.availabilityMessage ?? store.notice {
                        HStack(alignment: .firstTextBaseline) {
                            Label(message, systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            if store.availabilityMessage != nil {
                                Button("Check again") { store.refreshAvailability() }
                                    .buttonStyle(.borderless)
                                    .font(.system(size: 11))
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(18)
            }
            .onChange(of: store.messages.last?.text) { _, _ in
                if let id = store.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func messageView(_ message: LocalAIToolsStore.Message) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 36) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.role == .user ? "You" : "On-device AI")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(message.role == .user ? accentColor : .secondary)
                Text(message.text.isEmpty ? "Thinking…" : message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: 560, alignment: .leading)
            .background(message.role == .user ? accentColor.opacity(0.13) : .white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 36) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $store.draft)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .focused($composerFocused)
                .frame(minHeight: 58, maxHeight: 100)
                .padding(7)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityLabel("Message for on-device AI")
                .disabled(store.conversationEnded)
            HStack {
                Text("Responses may be inaccurate. Nothing is sent to an external AI service.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                if store.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { store.cancel() }
                        .buttonStyle(.bordered)
                } else {
                    Button("Send", systemImage: "arrow.up") { store.send() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canSend)
                }
            }
        }
        .padding(18)
    }
}
