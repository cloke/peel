//
//  ModelLabView.swift
//  Peel
//
//  Labs view for browsing and trying out MLX models.
//  Shows all available models grouped by category with a simple
//  prompt interface for text generation models.
//

import SwiftUI

#if os(macOS)
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Model Lab View

struct ModelLabView: View {
  @State private var selectedCategory: MLXModelCategory = .editor
  @State private var selectedModel: MLXModelEntry?
  @State private var showingChat = false
  @State private var viewModel = ModelLabViewModel()

  var body: some View {
    NavigationSplitView {
      categorySidebar
    } detail: {
      if let model = selectedModel {
        ModelDetailView(
          model: model,
          category: selectedCategory,
          viewModel: viewModel
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

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        modelHeader
        modelInfo
        if category.supportsChat {
          chatSection
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
    case .tts:
      return "Text-to-speech support is coming soon.\nModels use mlx-audio for real-time voice synthesis."
    case .stt:
      return "Speech-to-text support is coming soon.\nModels use mlx-audio for local transcription."
    case .embedding:
      return "Embedding models are used by the RAG system.\nConfigure embeddings in Settings > RAG."
    default:
      return "This model type is not yet interactive."
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

#endif
