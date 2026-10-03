#if canImport(SwiftUI) && canImport(UIKit)
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

                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, m in
                        bubble(m, showName: m.sender == .agent && (index == 0 || session.messages[index - 1].sender != .agent))
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

    @ViewBuilder
    private func bubble(_ m: ChatMessage, showName: Bool) -> some View {
        switch m.sender {
        case .system:
            Text(m.body).font(.footnote).foregroundColor(.secondary).frame(maxWidth: .infinity)
        case .visitor:
            HStack {
                Spacer(minLength: 48)
                Text(m.body)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).fill(accent))
            }
        case .agent:
            VStack(alignment: .leading, spacing: 2) {
                if showName, let n = m.authorName {
                    Text(n).font(.caption).foregroundColor(.secondary).padding(.leading, 4)
                }
                HStack {
                    Text(m.body)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                    Spacer(minLength: 48)
                }
            }
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
