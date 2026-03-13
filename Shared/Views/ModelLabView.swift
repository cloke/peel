//
//  ModelLabView.swift
//  Peel
//
//  Labs view for browsing and trying out MLX models.
//  Shows all available models grouped by category with a simple
//  prompt interface for text generation models.
//

import SwiftUI

import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Model Lab View

struct ModelLabView: View {
  @State private var selectedCategory: MLXModelCategory = .editor
  @State private var selectedModel: MLXModelEntry?
  @State private var showingChat = false
  @State private var viewModel = ModelLabViewModel()
  @State private var ttsService = MLXTTSService()
  @State private var sttService = MLXSTTService()

  var body: some View {
    NavigationSplitView {
      categorySidebar
    } detail: {
      if let model = selectedModel {
        ModelDetailView(
          model: model,
          category: selectedCategory,
          viewModel: viewModel,
          ttsService: ttsService,
          sttService: sttService
        )
      } else {
        ContentUnavailableView(
          "Select a Model",
          systemImage: "cpu",
          description: Text("Choose a model from the sidebar to view details.")
        )
      }
    }
    .navigationTitle("Model Lab")
  }

  private var categorySidebar: some View {
    List(selection: $selectedModel) {
      ForEach(MLXModelRegistry.shared.allModelsByCategory, id: \.category) { group in
        Section(group.category.rawValue) {
          ForEach(group.models) { model in
            ModelSidebarRow(model: model, category: group.category)
              .tag(model)
              .onTapGesture {
                selectedCategory = group.category
                selectedModel = model
              }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
  }
}

// MARK: - Sidebar Row

struct ModelSidebarRow: View {
  let model: MLXModelEntry
  let category: MLXModelCategory

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: category.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(model.name)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Text(model.tier)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: - Model Detail View

struct ModelDetailView: View {
  let model: MLXModelEntry
  let category: MLXModelCategory
  @Bindable var viewModel: ModelLabViewModel
  @Bindable var ttsService: MLXTTSService
  @Bindable var sttService: MLXSTTService

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        modelHeader
        modelInfo
        if category.supportsChat {
          chatSection
        } else if category == .tts {
          ttsSection
        } else if category == .stt {
          sttSection
        } else {
          capabilityCallout
        }
      }
      .padding(24)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Header

  private var modelHeader: some View {
    HStack(spacing: 16) {
      ZStack {
        RoundedRectangle(cornerRadius: 12)
          .fill(.quaternary)
          .frame(width: 56, height: 56)
        Image(systemName: category.systemImage)
          .font(.title2)
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(model.name)
          .font(.title2.weight(.semibold))
        Text(model.huggingFaceId)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer()
      tierBadge
    }
  }

  private var tierBadge: some View {
    Text(model.tier.capitalized)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .background(.blue.opacity(0.12), in: Capsule())
      .foregroundStyle(.blue)
  }

  // MARK: - Info Grid

  private var modelInfo: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let description = model.description {
        Text(description)
          .font(.body)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible()),
      ], spacing: 12) {
        if let size = model.estimatedSizeGB {
          infoCard(title: "Disk Size", value: String(format: "%.1f GB", size), icon: "internaldrive")
        }
        if let ram = model.minimumRAMGB {
          infoCard(title: "Min RAM", value: String(format: "%.0f GB", ram), icon: "memorychip")
        }
        if let ctx = model.contextLength {
          infoCard(title: "Context", value: formatTokens(ctx), icon: "text.alignleft")
        }
        if let tokens = model.maxTokens {
          infoCard(title: "Max Output", value: formatTokens(tokens), icon: "text.cursor")
        }
        if let dims = model.dimensions {
          infoCard(title: "Dimensions", value: "\(dims)d", icon: "cube")
        }
      }
    }
  }

  private func infoCard(title: String, value: String, icon: String) -> some View {
    VStack(spacing: 6) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
  }

  private func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 {
      return "\(count / 1_000_000)M"
    } else if count >= 1_000 {
      return "\(count / 1_000)K"
    }
    return "\(count)"
  }

  // MARK: - Chat Section

  private var chatSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Try It Out", systemImage: "bubble.left.and.bubble.right")
        .font(.headline)

      // Messages
      if !viewModel.messages.isEmpty {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(viewModel.messages) { message in
                ChatBubble(message: message)
                  .id(message.id)
              }
            }
            .padding(.vertical, 8)
          }
          .frame(maxHeight: 400)
          .background(.background.secondary)
          .clipShape(RoundedRectangle(cornerRadius: 8))
          .onChange(of: viewModel.messages.count) { _, _ in
            if let last = viewModel.messages.last {
              proxy.scrollTo(last.id, anchor: .bottom)
            }
          }
        }
      }

      // Input
      HStack(spacing: 8) {
        TextField("Ask something…", text: $viewModel.inputText, axis: .vertical)
          .textFieldStyle(.plain)
          .padding(8)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
          .lineLimit(1...5)
          .onSubmit {
            if !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Task {
                await viewModel.generate(with: model)
              }
            }
          }

        Button {
          Task {
            await viewModel.generate(with: model)
          }
        } label: {
          if viewModel.isGenerating {
            ProgressView()
              .controlSize(.small)
              .frame(width: 28, height: 28)
          } else {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
          }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isGenerating)
      }

      if viewModel.isGenerating {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text(viewModel.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Stop") {
            viewModel.stopGenerating()
          }
          .font(.caption)
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }

      if let error = viewModel.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
  }

  // MARK: - Non-Chat Callout

  private var capabilityCallout: some View {
    VStack(spacing: 12) {
      Image(systemName: category.systemImage)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(capabilityDescription)
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
  }

  private var capabilityDescription: String {
    switch category {
    case .imageGeneration:
      return "Image generation support is coming soon.\nModels use DiffusionKit and run locally on Apple Silicon."
    case .embedding:
      return "Embedding models are used by the RAG system.\nConfigure embeddings in Settings > RAG."
    default:
      return "This model type is not yet interactive."
    }
  }

  // MARK: - TTS Section

  @State private var ttsInputText = ""
  @State private var ttsVoice = ""

  private var ttsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Text-to-Speech", systemImage: "speaker.wave.3")
        .font(.headline)

      TextField("Enter text to speak…", text: $ttsInputText, axis: .vertical)
        .textFieldStyle(.plain)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .lineLimit(2...8)

      HStack(spacing: 12) {
        TextField("Voice (optional)", text: $ttsVoice)
          .textFieldStyle(.plain)
          .padding(8)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
          .frame(maxWidth: 200)

        Spacer()

        if ttsService.isGenerating {
          Button("Stop") {
            ttsService.stop()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Button {
          Task {
            await ttsService.generateAndPlay(
              text: ttsInputText.trimmingCharacters(in: .whitespacesAndNewlines),
              modelId: model.huggingFaceId,
              voice: ttsVoice.isEmpty ? nil : ttsVoice
            )
          }
        } label: {
          if ttsService.isGenerating {
            ProgressView()
              .controlSize(.small)
              .frame(width: 28, height: 28)
          } else {
            Label("Speak", systemImage: "play.fill")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(
          ttsInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ttsService.isGenerating
        )
      }

      if ttsService.isGenerating || ttsService.isLoading {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text(ttsService.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let error = ttsService.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Playback controls
      if ttsService.audioPlayer.isPlaying || ttsService.audioPlayer.duration > 0 {
        HStack(spacing: 12) {
          Button {
            ttsService.audioPlayer.togglePlayPause()
          } label: {
            Image(
              systemName: ttsService.audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill"
            )
            .font(.title2)
          }
          .buttonStyle(.plain)

          if ttsService.audioPlayer.duration > 0 {
            Text(
              String(
                format: "%.1fs / %.1fs",
                ttsService.audioPlayer.currentTime,
                ttsService.audioPlayer.duration
              ))
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }

          Spacer()

          Button {
            ttsService.audioPlayer.stop()
          } label: {
            Image(systemName: "stop.circle")
              .font(.title3)
          }
          .buttonStyle(.plain)
        }
        .padding(.top, 4)
      }

      voiceHints
    }
  }

  private var voiceHints: some View {
    DisclosureGroup("Voice Options") {
      VStack(alignment: .leading, spacing: 4) {
        Text("Voice names depend on the model. Common options:")
          .font(.caption)
          .foregroundStyle(.secondary)
        Group {
          Text("**Orpheus**: tara, leah, jess, leo, dan, mia, zac, zoe")
          Text("**Soprano**: default (leave empty)")
          Text("**Qwen3-TTS**: leave empty for default voice")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      .padding(.top, 4)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: - STT Section

  @State private var sttFileURL: URL?
  @State private var sttTranscriptionResult: String?
  @State private var showingFileImporter = false

  private var sttSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("Speech-to-Text", systemImage: "mic")
        .font(.headline)

      HStack(spacing: 12) {
        Button {
          showingFileImporter = true
        } label: {
          Label(
            sttFileURL?.lastPathComponent ?? "Choose Audio File…",
            systemImage: "doc.badge.plus"
          )
        }
        .buttonStyle(.bordered)

        Spacer()

        if sttService.isTranscribing {
          Button("Stop") {
            sttService.stop()
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }

        Button {
          guard let url = sttFileURL else { return }
          Task {
            sttTranscriptionResult = await sttService.transcribe(
              audioURL: url,
              modelId: model.huggingFaceId
            )
          }
        } label: {
          if sttService.isTranscribing {
            ProgressView()
              .controlSize(.small)
              .frame(width: 28, height: 28)
          } else {
            Label("Transcribe", systemImage: "text.bubble")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(sttFileURL == nil || sttService.isTranscribing)
      }
      .fileImporter(
        isPresented: $showingFileImporter,
        allowedContentTypes: [.audio, .wav, .mp3, .aiff],
        allowsMultipleSelection: false
      ) { result in
        if case .success(let urls) = result, let url = urls.first {
          sttFileURL = url
        }
      }

      if sttService.isTranscribing || sttService.isLoading {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.mini)
          Text(sttService.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if let error = sttService.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let transcription = sttTranscriptionResult {
        VStack(alignment: .leading, spacing: 6) {
          Label("Transcription", systemImage: "text.quote")
            .font(.subheadline.weight(.medium))
          Text(transcription)
            .font(.body)
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.top, 4)
      }
    }
  }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
  let message: LabChatMessage

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 60) }
      Text(message.content)
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
          message.role == .user ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .textSelection(.enabled)
      if message.role == .assistant { Spacer(minLength: 60) }
    }
    .padding(.horizontal, 8)
  }
}

// MARK: - Chat State

struct LabChatMessage: Identifiable, Sendable {
  let id = UUID()
  let role: Role
  let content: String

  enum Role: Sendable {
    case user, assistant
  }
}

// MARK: - View Model

@MainActor
@Observable
class ModelLabViewModel {
  var messages: [LabChatMessage] = []
  var inputText = ""
  var isGenerating = false
  var statusText = "Loading model…"
  var errorMessage: String?

  private var generateTask: Task<Void, Never>?

  func generate(with model: MLXModelEntry) async {
    let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !isGenerating else { return }

    inputText = ""
    errorMessage = nil
    messages.append(LabChatMessage(role: .user, content: prompt))
    isGenerating = true
    statusText = "Loading model…"

    generateTask = Task {
      do {
        let container = try await loadModel(id: model.huggingFaceId)
        statusText = "Generating…"

        // Build chat messages
        let chatMessages: [Chat.Message] = messages.map { msg in
          msg.role == .user ? .user(msg.content) : .assistant(msg.content)
        }
        nonisolated(unsafe) let input = UserInput(
          chat: [.system("You are a helpful assistant.")] + chatMessages
        )

        let maxTokens = model.maxTokens ?? 4096
        let parameters = GenerateParameters(
          maxTokens: maxTokens,
          temperature: 0.7,
          topP: 0.9
        )

        let lmInput = try await container.prepare(input: input)
        let stream = try await container.generate(input: lmInput, parameters: parameters)

        var outputText = ""
        for await generation in stream {
          if Task.isCancelled { break }
          switch generation {
          case .chunk(let text):
            outputText += text
          case .info:
            break
          case .toolCall:
            break
          }
        }

        if !Task.isCancelled {
          let finalText = outputText.isEmpty ? "(empty response)" : outputText
          messages.append(LabChatMessage(role: .assistant, content: finalText))
        }
      } catch is CancellationError {
        // User stopped
      } catch {
        errorMessage = error.localizedDescription
      }
      isGenerating = false
    }
  }

  func stopGenerating() {
    generateTask?.cancel()
    generateTask = nil
    isGenerating = false
    statusText = "Stopped"
  }

  // MARK: - Model Loading

  private var modelCache: [String: ModelContainer] = [:]

  private func loadModel(id: String) async throws -> ModelContainer {
    if let cached = modelCache[id] {
      return cached
    }
    let config = ModelConfiguration(id: id)
    let container = try await LLMModelFactory.shared.loadContainer(configuration: config) { progress in
      Task { @MainActor in
        self.statusText = "Downloading… \(Int(progress.fractionCompleted * 100))%"
      }
    }
    modelCache[id] = container
    return container
  }
}

