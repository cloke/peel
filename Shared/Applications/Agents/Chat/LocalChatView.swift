//
//  LocalChatView.swift
//  Peel
//
//  Simple chat interface for interacting with local MLX LLM models.
//  Supports model tier selection, streaming responses, and conversation history.
//
//  Created on 2/10/26.
//

#if os(macOS)
import SwiftUI
import SwiftData

// MARK: - View Model

@MainActor
@Observable
class LocalChatViewModel {
  var messages: [ChatMessage] = []
  var inputText = ""
  var isGenerating = false
  var isLoadingModel = false
  var currentStreamText = ""
  var selectedTier: MLXEditorModelTier = .auto
  var error: String?
  var tokensPerSecond: Double = 0
  var selectedRepoPath: String?
  var activeSkillCount = 0

  private var chatService: MLXChatService?
  private var generationTask: Task<Void, Never>?

  var modelStatusText: String {
    if isLoadingModel { return "Loading model..." }
    if let service = chatService {
      var status = "\(service.modelName) (\(service.tier.rawValue)) ready"
      if activeSkillCount > 0 {
        status += " · \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s")"
      }
      return status
    }
    let rec = MLXEditorModelConfig.recommendedModel()
    return "Will load: \(rec.name) (\(rec.huggingFaceId))"
  }

  var isModelLoaded: Bool {
    chatService != nil
  }

  /// Build a ChatContext from the current repo selection using DataService
  func buildContext(dataService: DataService?) -> ChatContext {
    guard let dataService, let repoPath = selectedRepoPath else {
      return .empty
    }

    var context = ChatContext()

    // Auto-seed Ember skills if needed
    let seededCount = DefaultSkillsService.autoSeedEmberSkillsIfNeeded(
      context: dataService.modelContext,
      repoPath: repoPath
    )
    if seededCount > 0 {
      print("[LocalChat] Auto-seeded \(seededCount) Ember skills for \(repoPath)")
    }

    // Fetch skills block (same format used by agent chains)
    let repoRemoteURL = RepoRegistry.shared.getCachedRemoteURL(for: repoPath)
    if let (skillsBlock, skills) = dataService.repoGuidanceSkillsBlock(
      repoPath: repoPath,
      repoRemoteURL: repoRemoteURL
    ) {
      context.skills = skillsBlock
      activeSkillCount = skills.count
      dataService.markRepoGuidanceSkillsApplied(skills)
    } else {
      activeSkillCount = 0
    }

    // Add repo info
    let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
    context.repoInfo = "Repository: \(repoName)\nPath: \(repoPath)"

    return context
  }

  func send(dataService: DataService?) {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isGenerating else { return }

    messages.append(ChatMessage(role: .user, content: text))
    inputText = ""
    isGenerating = true
    error = nil
    currentStreamText = ""
    tokensPerSecond = 0

    generationTask = Task {
      do {
        // Create service lazily on first send
        if chatService == nil {
          isLoadingModel = true
          let context = buildContext(dataService: dataService)
          let newService = MLXChatService(tier: selectedTier, context: context)
          chatService = newService
          // Show which model is being loaded
          var loadingMsg = "Loading **\(newService.modelName)** (\(newService.huggingFaceId))..."
          if activeSkillCount > 0 {
            loadingMsg += " with \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s")"
          }
          messages.append(ChatMessage(role: .system, content: loadingMsg))
        }

        guard let service = chatService else { return }

        let startTime = Date()
        var tokenCount = 0

        let stream = try await service.sendMessage(text)
        isLoadingModel = false

        // Update the system message to show model is ready
        if let idx = messages.lastIndex(where: { $0.role == .system }) {
          var readyMsg = "**\(service.modelName)** (\(service.huggingFaceId)) ready"
          if activeSkillCount > 0 {
            readyMsg += " · \(activeSkillCount) skill\(activeSkillCount == 1 ? "" : "s") loaded"
          }
          messages[idx] = ChatMessage(role: .system, content: readyMsg)
        }

        for await chunk in stream {
          currentStreamText += chunk
          tokenCount += 1

          // Update tokens/sec periodically
          if tokenCount % 10 == 0 {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed > 0 {
              tokensPerSecond = Double(tokenCount) / elapsed
            }
          }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed > 0 {
          tokensPerSecond = Double(tokenCount) / elapsed
        }

        // Add the complete response as a message
        if !currentStreamText.isEmpty {
          messages.append(ChatMessage(role: .assistant, content: currentStreamText))
        }
        currentStreamText = ""
        isGenerating = false

      } catch {
        self.error = error.localizedDescription
        isGenerating = false
        isLoadingModel = false
        currentStreamText = ""
      }
    }
  }

  func stop() {
    generationTask?.cancel()
    generationTask = nil
    if !currentStreamText.isEmpty {
      messages.append(ChatMessage(role: .assistant, content: currentStreamText + " [stopped]"))
      currentStreamText = ""
    }
    isGenerating = false
  }

  func clearChat() {
    messages.removeAll()
    currentStreamText = ""
    error = nil
    Task {
      await chatService?.clearHistory()
    }
  }

  func switchModel(to tier: MLXEditorModelTier) {
    guard tier != selectedTier || chatService == nil else { return }
    selectedTier = tier
    // Nil out chatService immediately so send() creates a new one for the new tier.
    // Then unload the old model's memory in the background.
    let oldService = chatService
    chatService = nil
    if let oldService {
      Task { await oldService.unload() }
    }
  }

  /// Update the repo context — refreshes skills and injects into active session
  func setRepo(_ repoPath: String?, dataService: DataService?) {
    selectedRepoPath = repoPath
    let context = buildContext(dataService: dataService)
    if let service = chatService {
      Task { await service.updateContext(context) }
    }
  }

  func unloadModel() {
    Task {
      await chatService?.unload()
      chatService = nil
    }
  }
}

// MARK: - Chat View

struct LocalChatView: View {
  @State private var viewModel = LocalChatViewModel()
  @Environment(DataService.self) private var dataService
  @FocusState private var inputFocused: Bool

  /// Computed list of repos from the registry
  private var availableRepos: [(name: String, path: String)] {
    RepoRegistry.shared.registeredRepos
      .map { (name: URL(fileURLWithPath: $0.localPath).lastPathComponent, path: $0.localPath) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Messages area
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if viewModel.messages.isEmpty && !viewModel.isGenerating {
              welcomeView
            }

            ForEach(viewModel.messages) { message in
              MessageBubble(message: message)
                .id(message.id)
            }

            // Streaming response
            if viewModel.isGenerating && !viewModel.currentStreamText.isEmpty {
              StreamingBubble(text: viewModel.currentStreamText)
                .id("streaming")
            }

            if viewModel.isLoadingModel {
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
        .onChange(of: viewModel.messages.count) {
          withAnimation {
            if let lastId = viewModel.messages.last?.id {
              proxy.scrollTo(lastId, anchor: .bottom)
            }
          }
        }
        .onChange(of: viewModel.currentStreamText) {
          withAnimation {
            proxy.scrollTo("streaming", anchor: .bottom)
          }
        }
      }

      Divider()

      // Status bar
      HStack(spacing: 12) {
        // Model picker — menu style scales better than segmented with 5+ items
        Picker("Model", selection: Binding(
          get: { viewModel.selectedTier },
          set: { viewModel.switchModel(to: $0) }
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

        // Repo picker — attaches skills/context from the selected repo
        Picker("Repo", selection: Binding(
          get: { viewModel.selectedRepoPath ?? "" },
          set: { viewModel.setRepo($0.isEmpty ? nil : $0, dataService: dataService) }
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

        if viewModel.isGenerating && viewModel.tokensPerSecond > 0 {
          Text(String(format: "%.1f tok/s", viewModel.tokensPerSecond))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        Text(viewModel.modelStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)
      .padding(.vertical, 6)
      .background(.bar)

      Divider()

      // Input area
      HStack(alignment: .bottom, spacing: 8) {
        TextEditor(text: $viewModel.inputText)
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
              viewModel.send(dataService: dataService)
            }
          }

        if viewModel.isGenerating {
          Button {
            viewModel.stop()
          } label: {
            Image(systemName: "stop.circle.fill")
              .font(.title2)
              .foregroundStyle(.red)
          }
          .buttonStyle(.plain)
          .help("Stop generating")
        } else {
          Button {
            viewModel.send(dataService: dataService)
          } label: {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
              .foregroundStyle(.blue)
          }
          .buttonStyle(.plain)
          .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .help("Send message (Enter)")
          .keyboardShortcut(.return, modifiers: [])
        }
      }
      .padding(.horizontal)
      .padding(.vertical, 8)

      if let error = viewModel.error {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(error)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Dismiss") { viewModel.error = nil }
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
          viewModel.clearChat()
        } label: {
          Label("Clear Chat", systemImage: "trash")
        }
        .help("Clear conversation")
        .disabled(viewModel.messages.isEmpty)

        Button {
          viewModel.unloadModel()
        } label: {
          Label("Unload Model", systemImage: "memorychip")
        }
        .help("Unload model to free memory")
        .disabled(!viewModel.isModelLoaded)
      }
    }
    .onAppear {
      inputFocused = true
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
          viewModel.inputText = "Explain @Observable vs ObservableObject in Swift 6"
          viewModel.send(dataService: dataService)
        }
        SuggestionButton(text: "Help me refactor a Combine pipeline to async/await") {
          viewModel.inputText = "Help me refactor a Combine pipeline to async/await"
          viewModel.send(dataService: dataService)
        }
        SuggestionButton(text: "What's the actor reentrancy problem in Swift?") {
          viewModel.inputText = "What's the actor reentrancy problem in Swift?"
          viewModel.send(dataService: dataService)
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
