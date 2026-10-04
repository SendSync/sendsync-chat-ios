#if canImport(SwiftUI) && canImport(UIKit)
#if canImport(PhotosUI)
import PhotosUI
#endif
import SwiftUI
import UIKit

/// The ready-made chat screen. Present it however your app presents screens:
/// a sheet, a navigation push, a tab.
public struct SendSyncChatView: View {
    @ObservedObject private var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var name = ""
    @State private var email = ""

    /// Uses the session from `SendSyncChat.configure(widgetKey:)`.
    @MainActor
    public init() {
        guard let s = SendSyncChat.session else {
            preconditionFailure("Call SendSyncChat.configure(widgetKey:) before showing SendSyncChatView")
        }
        self.session = s
    }

    public init(session: ChatSession) {
        self.session = session
    }

    private var accent: Color { Color(hex: session.config?.color) ?? .accentColor }

    public var body: some View {
        VStack(spacing: 0) {
            header
            messagesList
            Divider()
            footer
        }
        .task { await session.load() }
        .onAppear { session.setVisible(true) }
        .onDisappear { session.setVisible(false) }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.config?.title ?? " ").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.isOnline ? Color.green : Color.white.opacity(0.6))
                        .frame(width: 8, height: 8)
                    Text(session.isOnline ? "We're online" : "We're away right now").font(.footnote)
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold))
            }
            .accessibilityLabel("Close chat")
        }
        .foregroundColor(.white)
        .padding()
        .background(accent)
    }

    // MARK: messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(session.introText)
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))

                    if session.hasHistory {
                        earlierChats
                    }

                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, m in
                        bubble(m, showName: ChatMessage.showsAuthor(in: session.messages, at: index))
                            .id(m.id)
                    }
                    if session.hasEnded {
                        Text("This chat has ended.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
                .padding()
            }
            .onChange(of: session.messages.count) { _ in
                if let last = session.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// Everything this customer has said to you before, open or ended.
    ///
    /// Ended ones belong here and used to be missing: an agent closing a chat
    /// does not unsay what was in it, and a customer whose conversations had
    /// all been closed opened the app to a blank new chat with no way back to
    /// any of them — including one holding a reply they had never read.
    ///
    /// A plain list rather than a second screen: it keeps the whole thing one
    /// tap deep, which is the right shape for something most people will open
    /// once.
    @ViewBuilder
    private var earlierChats: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Earlier chats")
                .font(.caption).foregroundColor(.secondary)
            ForEach(session.history.filter { $0.id != session.conversationId }) { c in
                Button {
                    session.select(conversationId: c.id)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.lastMessagePreview ?? "No messages")
                                .font(.footnote)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                if let d = c.lastMessageAt {
                                    Text(d.formatted(date: .abbreviated, time: .shortened))
                                }
                                if !c.isOpen { Text("· Ended") }
                            }
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if c.unreadCount > 0 {
                            Text("\(c.unreadCount)")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(accent))
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func bubble(_ m: ChatMessage, showName: Bool) -> some View {
        switch m.sender {
        case .system:
            VStack(spacing: 2) {
                if showName, let n = m.authorName {
                    Text(n).font(.caption2).foregroundColor(.secondary)
                }
                Text(m.body).font(.footnote).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        case .visitor:
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    // A photo sent without a caption has an empty body, and an
                    // empty bubble above the picture reads as a failure.
                    if !m.body.isEmpty {
                        Text(m.body)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 16).fill(accent))
                    }
                    ForEach(m.attachments) { attachment($0) }
                }
            }
        case .agent:
            VStack(alignment: .leading, spacing: 2) {
                if showName, let n = m.authorName {
                    Text(n).font(.caption).foregroundColor(.secondary).padding(.leading, 4)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if !m.body.isEmpty {
                            Text(m.body)
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                        }
                        ForEach(m.attachments) { attachment($0) }
                    }
                    Spacer(minLength: 48)
                }
            }
        }
    }

    /// An image on a message.
    /// The link is signed and short-lived, so a chat left open long enough
    /// will fail to load one — the file name takes its place rather than a
    /// broken frame, and reopening the chat fetches a fresh link.
    @ViewBuilder
    private func attachment(_ a: ChatAttachment) -> some View {
        if let url = a.url.flatMap({ URL(string: $0) }) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220)
                case .failure:
                    Text(a.fileName).font(.footnote).foregroundColor(.secondary)
                default:
                    ProgressView().frame(width: 56, height: 56)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
        } else {
            Text(a.fileName).font(.footnote).foregroundColor(.secondary)
        }
    }

    // MARK: footer: picker, composer, or ended

    @ViewBuilder
    private var footer: some View {
        if session.hasEnded {
            Button("Start a new chat") { session.startNewChat() }
                .padding()
        } else if session.needsPipelineChoice {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose a team").font(.footnote).foregroundColor(.secondary)
                ForEach(session.pipelines) { p in
                    Button {
                        session.selectedPipelineId = p.id
                    } label: {
                        HStack {
                            Text(p.name).fontWeight(.semibold)
                            Spacer()
                            Circle().fill(p.online ? Color.green : Color.gray.opacity(0.5)).frame(width: 8, height: 8)
                            Text(p.online ? "Online" : "Away").font(.footnote).foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        } else {
            composer
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let first = session.conversationId == nil
            if first, session.pipelines.count > 1, let p = session.selectedPipeline {
                Button("← \(p.name) · change") { session.selectedPipelineId = nil }
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            if first && !session.isIdentified {
                HStack {
                    TextField("Your name (optional)", text: $name)
                        .textContentType(.name)
                    TextField(session.isOnline ? "Email (optional)" : "Your email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error = session.errorMessage {
                Text(error).font(.footnote).foregroundColor(.red)
            }
            HStack(alignment: .bottom) {
                // Only where the widget allows images, there is a chat to
                // attach one to, and the OS is new enough for the picker.
                #if canImport(PhotosUI)
                if #available(iOS 16.0, *), session.canAttachImages {
                    PhotoButton(tint: accent, disabled: session.isSending) { data in
                        let caption = draft.trimmingCharacters(in: .whitespaces)
                        // The caption rides with the image as one message, so
                        // the draft is cleared here rather than on success.
                        draft = ""
                        Task { await session.send(image: data, caption: caption) }
                    }
                }
                #endif
                TextField("Type your message…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .foregroundColor(accent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || session.isSending)
                .accessibilityLabel("Send")
            }
        }
        .padding()
    }

    @MainActor
    private func send() {
        let text = draft
        draft = ""
        Task {
            // nil, not "". These fields are only shown to anonymous visitors,
            // so for an identified user they are empty — and an empty string
            // is still a value, which meant `name ?? identity?.name` in
            // ChatSession never reached the name we already knew.
            await session.send(
                text,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
                email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : email
            )
            if session.errorMessage != nil, draft.isEmpty { draft = text }
        }
    }
}

#if canImport(PhotosUI)
/// The photo button, kept in its own view because `PhotosPicker` is iOS 16+
/// and the rest of this screen is not.
@available(iOS 16.0, *)
private struct PhotoButton: View {
    let tint: Color
    let disabled: Bool
    let onPicked: (Data) -> Void
    @State private var item: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, photoLibrary: .shared()) {
            Image(systemName: "photo").font(.title3)
        }
        .foregroundColor(tint)
        .disabled(disabled)
        .accessibilityLabel("Attach a photo")
        .onChange(of: item) { newValue in
            guard let newValue else { return }
            Task { @MainActor in
                let data = try? await newValue.loadTransferable(type: Data.self)
                // Cleared either way, so picking the same photo again still
                // registers as a change.
                item = nil
                if let data { onPicked(data) }
            }
        }
    }
}
#endif

extension Color {
    /// "#RRGGBB" → Color.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

// MARK: - UIKit

extension SendSyncChat {
    /// Present the chat as a sheet over `viewController` (UIKit apps).
    ///
    /// A page sheet rather than full screen: it is the idiom iOS users expect
    /// for something they will dismiss and come back to, and it keeps the
    /// host app visible behind. Pass `.fullScreen` yourself if you would
    /// rather it took the whole screen.
    public static func present(
        from viewController: UIViewController,
        animated: Bool = true,
        modalPresentationStyle: UIModalPresentationStyle = .pageSheet
    ) {
        let host = UIHostingController(rootView: SendSyncChatView())
        host.modalPresentationStyle = modalPresentationStyle
        viewController.present(host, animated: animated)
    }
}
#endif
