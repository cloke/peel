//
//  LocalChatView.swift
//  Peel
//
//  Simple chat interface for interacting with local MLX LLM models.
//  Supports model tier selection, streaming responses, and conversation history.
//  Messages sent via MCP (chat.send) appear here in real time via SharedChatSession.
//
//  Created on 2/10/26.
//

#if os(macOS)
import SwiftUI
import SwiftData

// MARK: - Chat View

struct LocalChatView: View {
  @Environment(DataService.self) private var dataService
  @Environment(MCPServerService.self) private var mcpServer
  @FocusState private var inputFocused: Bool
  @State private var inputText = ""
  @State private var availableRepos: [(name: String, path: String)] = []

  /// Convenience accessor for the shared chat session
  private var session: SharedChatSession {
    mcpServer.chatSession
  }

  /// Refresh the repo list from the RepoRegistry
  private func refreshRepoList() {
    availableRepos = RepoRegistry.shared.registeredRepos
      .map { (name: URL(fileURLWithPath: $0.localPath).lastPathComponent, path: $0.localPath) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func send() {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    inputText = ""
    session.sendFromUI(text, dataService: dataService, mcpServer: mcpServer)
  }

  var body: some View {
    VStack(spacing: 0) {
      // Messages area
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if session.messages.isEmpty && !session.isGenerating {
              welcomeView
            }

            ForEach(session.messages) { message in
              MessageBubble(message: message)
                .id(message.id)
            }

            // Streaming response
            if session.isGenerating && !session.currentStreamText.isEmpty {
              StreamingBubble(text: session.currentStreamText)
                .id("streaming")
            }

            if session.isLoadingModel {
              HStack(spacing: 8) {
                ProgressView()
                  .controlSize(.small)
                Text("Loading model...")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .padding(.horizontal)
              .id("loading")
            }
          }
          .padding()
        }
        .onChange(of: session.messages.count) {
          withAnimation {
            if let lastId = session.messages.last?.id {
              proxy.scrollTo(lastId, anchor: .bottom)
            }
          }
        }
        .onChange(of: session.currentStreamText) {
          withAnimation {
            proxy.scrollTo("streaming", anchor: .bottom)
          }
        }
      }

      Divider()

      // Status bar
      HStack(spacing: 12) {
        // Model picker
        Picker("Model", selection: Binding(
          get: { session.selectedTier },
          set: { session.switchModel(to: $0) }
        )) {
          Label("Auto", systemImage: "cpu")
            .tag(MLXEditorModelTier.auto)
          Divider()
          ForEach(MLXEditorModelConfig.availableModels, id: \.name) { model in
            Text(model.name).tag(model.tier)
          }
        }
        .pickerStyle(.menu)
        .fixedSize()

        // Repo picker
        Picker("Repo", selection: Binding(
          get: { session.selectedRepoPath ?? "" },
          set: { session.setRepo($0.isEmpty ? nil : $0, dataService: dataService) }
        )) {
          Label("No Repo", systemImage: "folder")
            .tag("")
          if !availableRepos.isEmpty {
            Divider()
            ForEach(availableRepos, id: \.path) { repo in
              Text(repo.name).tag(repo.path)
            }
          }
        }
        .pickerStyle(.menu)
        .fixedSize()

        Spacer()

        if session.ragSnippetCount > 0 {
          Label("\(session.ragSnippetCount) RAG", systemImage: "doc.text.magnifyingglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("\(session.ragSnippetCount) code snippets from local RAG index")
        }

        Button {
          session.useRAG.toggle()
        } label: {
          Image(systemName: session.useRAG ? "brain.filled.head.profile" : "brain.head.profile")
            .foregroundStyle(session.useRAG ? .blue : .secondary)
        }
        .buttonStyle(.plain)
        .help(session.useRAG ? "RAG enabled — click to disable" : "RAG disabled — click to enable")

        if session.isGenerating && session.tokensPerSecond > 0 {
          Text(String(format: "%.1f tok/s", session.tokensPerSecond))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        Text(session.modelStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.bar)

      Divider()

      // Input area
      HStack(alignment: .bottom, spacing: 8) {
        TextEditor(text: $inputText)
          .font(.body)
          .scrollContentBackground(.hidden)
          .frame(minHeight: 36, maxHeight: 120)
          .fixedSize(horizontal: false, vertical: true)
          .padding(8)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(.quaternary.opacity(0.5))
          )
          .focused($inputFocused)
          .onSubmit {
            if !NSEvent.modifierFlags.contains(.shift) {
              send()
            }
          }

        if session.isGenerating {
          Button {
            session.stop()
          } label: {
            Image(systemName: "stop.circle.fill")
              .font(.title2)
              .foregroundStyle(.red)
          }
          .buttonStyle(.plain)
          .help("Stop generating")
        } else {
          Button {
            send()
          } label: {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
              .foregroundStyle(.blue)
          }
          .buttonStyle(.plain)
          .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("Send message (Enter)")
          .keyboardShortcut(.return, modifiers: [])
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      if let error = session.error {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Dismiss") { session.error = nil }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
      }
    }
    .navigationTitle("Local Chat")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          session.clearChat()
        } label: {
          Label("Clear Chat", systemImage: "trash")
        }
        .help("Clear conversation")
        .disabled(session.messages.isEmpty)

        Button {
          session.unloadModel()
        } label: {
          Label("Unload Model", systemImage: "memorychip")
        }
        .help("Unload model to free memory")
        .disabled(!session.isModelLoaded)
      }
    }
    .onAppear {
      inputFocused = true
    }
    .task {
      // 1) Populate from SwiftData persisted repos
      let syncedRepos = dataService.getAllRepositories()
      var paths: [String] = []
      for repo in syncedRepos {
        if let mapping = dataService.getLocalPath(for: repo) {
          paths.append(mapping.localPath)
        }
      }

      // 2) Populate from RAG-indexed repos
      if let ragRepos = try? await mcpServer.localRagStore.listRepos() {
        for repo in ragRepos {
          let p = repo.rootPath
          if !paths.contains(p) && FileManager.default.fileExists(atPath: p) {
            paths.append(p)
          }
        }
      }

      // 3) Register all discovered paths
      if !paths.isEmpty {
        await RepoRegistry.shared.registerAllPaths(paths)
      }
      refreshRepoList()
    }
  }

  private var welcomeView: some View {
    VStack(spacing: 16) {
      Image(systemName: "bubble.left.and.bubble.right")
        .font(.system(size: 48))
        .foregroundStyle(.secondary)

      Text("Local Chat")
        .font(.title2)
        .fontWeight(.semibold)

      Text("Chat with a local LLM running on your Mac via MLX.\nNo data leaves your machine.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      VStack(alignment: .leading, spacing: 8) {
        SuggestionButton(text: "Explain @Observable vs ObservableObject in Swift 6") {
          inputText = "Explain @Observable vs ObservableObject in Swift 6"
          send()
        }
        SuggestionButton(text: "Help me refactor a Combine pipeline to async/await") {
          inputText = "Help me refactor a Combine pipeline to async/await"
          send()
        }
        SuggestionButton(text: "What's the actor reentrancy problem in Swift?") {
          inputText = "What's the actor reentrancy problem in Swift?"
          send()
        }
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.top, 60)
  }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
  let message: ChatMessage

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      if message.role == .assistant {
        Image(systemName: "cpu")
          .font(.caption)
          .foregroundStyle(.blue)
          .frame(width: 24, height: 24)
          .background(Circle().fill(.blue.opacity(0.15)))
      }

      VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
        Text(message.content)
          .textSelection(.enabled)
          .font(.body)
          .padding(10)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(message.role == .user ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
          )

        Text(message.timestamp, style: .time)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: 600, alignment: message.role == .user ? .trailing : .leading)

      if message.role == .user {
        Image(systemName: "person.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
      }
    }
    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
  }
}

// MARK: - Streaming Bubble

private struct StreamingBubble: View {
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "cpu")
        .font(.caption)
        .foregroundStyle(.blue)
        .frame(width: 24, height: 24)
        .background(Circle().fill(.blue.opacity(0.15)))

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 0) {
          Text(text)
            .textSelection(.enabled)
            .font(.body)

          // Blinking cursor
          Text("|")
            .font(.body)
            .foregroundStyle(.blue)
            .opacity(0.8)
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .fill(Color.secondary.opacity(0.1))
        )
      }
      .frame(maxWidth: 600, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Suggestion Button

private struct SuggestionButton: View {
  let text: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Image(systemName: "sparkles")
          .foregroundStyle(.blue)
        Text(text)
          .font(.callout)
          .multilineTextAlignment(.leading)
        Spacer()
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
      }
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(.quaternary.opacity(0.5))
      )
    }
    .buttonStyle(.plain)
  }
}

// Preview requires DataService with ModelContext — use Xcode canvas with app target
// #Preview {
//   LocalChatView()
//     .frame(width: 700, height: 600)
// }

#endif
