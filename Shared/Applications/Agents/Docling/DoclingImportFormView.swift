//
//  DoclingImportFormView.swift
//  Peel
//

import SwiftUI

#if os(macOS)
import AppKit

struct DoclingImportFormView: View {
  @Binding var inputPath: String
  @Binding var outputPath: String
  @Binding var profile: String
  @Binding var pythonPath: String
  @Binding var scriptPath: String
  let isRunning: Bool
  let conversionStatus: String
  let lastResult: DoclingService.ConvertResult?
  let conversionDuration: TimeInterval?
  let service: DoclingService
  let onConvert: () async -> Void

  var body: some View {
    ToolSection("Docling Import") {
      LabeledContent("Input PDF") {
        HStack(spacing: 8) {
          TextField("/path/to/policy.pdf", text: $inputPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.docling.inputPath")

          Button("Browse") {
            selectInputPDF()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.browseInput")
        }
      }

      LabeledContent("Output Markdown") {
        HStack(spacing: 8) {
          TextField("/path/to/policy.md", text: $outputPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.docling.outputPath")

          Button("Browse") {
            selectOutputFile()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.browseOutput")

          Button("Output Dir") {
            selectOutputDirectory()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.browseOutputDir")
        }
      }

      LabeledContent("Profile") {
        Picker("Profile", selection: $profile) {
          Text("High").tag("high")
          Text("Standard").tag("standard")
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 220)
        .accessibilityIdentifier("agents.docling.profile")
      }

      LabeledContent("Python path (optional)") {
        HStack(spacing: 8) {
          TextField("Auto-detect", text: $pythonPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.docling.pythonPath")

          Button("Detect") {
            if let detected = service.suggestedPythonPath() {
              pythonPath = detected
            }
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.detectPython")
        }
      }

      LabeledContent("Script path (optional)") {
        HStack(spacing: 8) {
          TextField("Auto-detect", text: $scriptPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.docling.scriptPath")

          Button("Detect") {
            if let detected = service.suggestedScriptPath() {
              scriptPath = detected
            }
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.detectScript")
        }
      }

      HStack(spacing: 8) {
        Button(isRunning ? "Converting..." : "Convert") {
          Task { await onConvert() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isRunning)
        .accessibilityIdentifier("agents.docling.convert")

        if isRunning {
          ProgressView()
            .scaleEffect(0.7)
        }

        if let lastResult, !isRunning {
          Button("Open Output") {
            openOutput(at: lastResult.outputPath)
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("agents.docling.openOutput")
        }
      }

      if isRunning, !conversionStatus.isEmpty {
        Text(conversionStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }

    if let lastResult {
      ToolSection("Last Conversion") {
        Text("Output: \(lastResult.outputPath)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("Size: \(formattedBytes(lastResult.bytesWritten))")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let conversionDuration {
          Text("Time: \(formattedDuration(conversionDuration))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func openOutput(at path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private func selectInputPDF() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [.pdf]
    if panel.runModal() == .OK, let url = panel.url {
      inputPath = url.path
      if outputPath.isEmpty {
        outputPath = url.deletingPathExtension().appendingPathExtension("md").path
      }
    }
  }

  private func selectOutputFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = suggestedOutputFilename()
    if panel.runModal() == .OK, let url = panel.url {
      outputPath = url.path
    }
  }

  private func selectOutputDirectory() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    if panel.runModal() == .OK, let url = panel.url {
      outputPath = url.appendingPathComponent(suggestedOutputFilename()).path
    }
  }

  private func suggestedOutputFilename() -> String {
    let inputURL = URL(fileURLWithPath: inputPath.isEmpty ? "output.pdf" : inputPath)
    let base = inputURL.deletingPathExtension().lastPathComponent
    return base.isEmpty ? "output.md" : "\(base).md"
  }

  private func formattedBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1_048_576 { return "\(bytes / 1024) KB" }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
  }

  private func formattedDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds))s" }
    return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60)))s"
  }
}
#endif
