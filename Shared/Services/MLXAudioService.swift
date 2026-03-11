//
//  MLXAudioService.swift
//  Peel
//
//  Service for TTS and STT using mlx-audio-swift.
//  Provides text-to-speech generation and speech-to-text transcription
//  running locally on Apple Silicon via MLX.
//

#if os(macOS)
import AVFoundation
import Foundation
import MLX
import MLXAudioCore
@preconcurrency import MLXAudioSTT
@preconcurrency import MLXAudioTTS
import os

/// Sendable wrapper for non-Sendable model protocols from mlx-audio-swift.
/// Access is serialized through @MainActor service classes.
private struct SendableBox<T>: @unchecked Sendable {
  let value: T
}

// MARK: - TTS Service

@MainActor
@Observable
final class MLXTTSService {
  var isLoading = false
  var isGenerating = false
  var statusText = ""
  var errorMessage: String?

  private let logger = Logger(subsystem: "com.peel.mlx", category: "TTS")
  private var cachedModel: SendableBox<SpeechGenerationModel>?
  private var loadedModelId: String?
  private var generateTask: Task<Void, Never>?

  let audioPlayer = AudioPlayer()

  /// Generate speech from text and play it via streaming audio.
  func generateAndPlay(
    text: String,
    modelId: String,
    voice: String? = nil,
    language: String? = nil
  ) async {
    guard !isGenerating else { return }

    isGenerating = true
    errorMessage = nil
    statusText = "Loading model…"

    generateTask = Task {
      do {
        let model = try await self.ensureModel(id: modelId)
        self.statusText = "Generating speech…"

        let stream = model.value.generatePCMBufferStream(
          text: text,
          voice: voice,
          refAudio: nil,
          refText: nil,
          language: language
        )

        self.audioPlayer.play(stream: stream)
        self.statusText = "Playing…"

        // Wait for playback to finish
        await withCheckedContinuation { continuation in
          self.audioPlayer.onDidFinishStreaming = {
            continuation.resume()
          }
        }
        self.audioPlayer.onDidFinishStreaming = nil

        if !Task.isCancelled {
          self.statusText = "Done"
        }
      } catch is CancellationError {
        self.statusText = "Stopped"
      } catch {
        self.logger.error("TTS generation failed: \(error.localizedDescription)")
        self.errorMessage = error.localizedDescription
        self.statusText = "Error"
      }

      self.isGenerating = false
    }
  }

  /// Generate speech and save to a WAV file. Returns the file URL.
  func generateToFile(
    text: String,
    modelId: String,
    voice: String? = nil,
    language: String? = nil,
    outputURL: URL
  ) async throws -> URL {
    statusText = "Loading model…"
    let model = try await ensureModel(id: modelId)

    statusText = "Generating speech…"
    let audio = try await model.value.generate(
      text: text,
      voice: voice,
      refAudio: nil,
      refText: nil,
      language: language
    )

    statusText = "Saving audio…"
    let samples = audio.asArray(Float.self)
    try AudioUtils.writeWavFile(
      samples: samples, sampleRate: Double(model.value.sampleRate), fileURL: outputURL)

    statusText = "Done"
    return outputURL
  }

  func stop() {
    generateTask?.cancel()
    generateTask = nil
    audioPlayer.stop()
    isGenerating = false
    statusText = "Stopped"
  }

  // MARK: - Model Loading

  private func ensureModel(id: String) async throws -> SendableBox<SpeechGenerationModel> {
    if let cached = cachedModel, loadedModelId == id {
      return cached
    }

    isLoading = true
    defer { isLoading = false }

    let model = try await TTS.loadModel(modelRepo: id)
    let box = SendableBox(value: model)
    cachedModel = box
    loadedModelId = id
    return box
  }
}

// MARK: - STT Service

@MainActor
@Observable
final class MLXSTTService {
  var isLoading = false
  var isTranscribing = false
  var statusText = ""
  var errorMessage: String?

  private let logger = Logger(subsystem: "com.peel.mlx", category: "STT")
  private var cachedModel: SendableBox<any STTGenerationModel>?
  private var loadedModelId: String?
  private var transcribeTask: Task<String?, Never>?

  /// Transcribe audio from a file URL. Returns transcribed text.
  func transcribe(
    audioURL: URL,
    modelId: String,
    language: String = "English"
  ) async -> String? {
    guard !isTranscribing else { return nil }

    isTranscribing = true
    errorMessage = nil
    statusText = "Loading model…"

    var result: String?

    transcribeTask = Task {
      do {
        let model = try await self.ensureModel(id: modelId)
        self.statusText = "Transcribing…"

        let (inputSampleRate, inputAudio) = try loadAudioArray(from: audioURL)
        let audio = self.prepareAudio(inputAudio, inputSampleRate: inputSampleRate)

        let params = STTGenerateParameters(
          language: language
        )

        let output = model.value.generate(audio: audio, generationParameters: params)
        result = output.text

        self.statusText = "Done"
      } catch is CancellationError {
        self.statusText = "Stopped"
      } catch {
        self.logger.error("STT transcription failed: \(error.localizedDescription)")
        self.errorMessage = error.localizedDescription
        self.statusText = "Error"
      }

      self.isTranscribing = false
      return result
    }

    return await transcribeTask?.value ?? nil
  }

  func stop() {
    transcribeTask?.cancel()
    transcribeTask = nil
    isTranscribing = false
    statusText = "Stopped"
  }

  // MARK: - Model Loading

  private func ensureModel(id: String) async throws -> SendableBox<any STTGenerationModel> {
    if let cached = cachedModel, loadedModelId == id {
      return cached
    }

    isLoading = true
    defer { isLoading = false }

    let lower = id.lowercased()
    let model: any STTGenerationModel

    if lower.contains("glmasr") || lower.contains("glm-asr") {
      model = try await GLMASRModel.fromPretrained(id)
    } else if lower.contains("qwen3-asr") || lower.contains("qwen3_asr") {
      model = try await Qwen3ASRModel.fromPretrained(id)
    } else if lower.contains("voxtral") {
      model = try await VoxtralRealtimeModel.fromPretrained(id)
    } else if lower.contains("parakeet") {
      model = try await ParakeetModel.fromPretrained(id)
    } else {
      model = try await Qwen3ASRModel.fromPretrained(id)
    }

    let box = SendableBox(value: model)
    cachedModel = box
    loadedModelId = id
    return box
  }

  /// Resample mono audio to 16kHz for STT models.
  private func prepareAudio(_ audio: MLXArray, inputSampleRate: Int) -> MLXArray {
    let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio
    guard inputSampleRate != 16000 else { return mono }
    return (try? MLXAudioCore.resampleAudio(mono, from: inputSampleRate, to: 16000)) ?? mono
  }
}

#endif
