//
//  PIIScrubberView.swift
//  KitchenSync
//
//  Created on 1/20/26.
//

import SwiftUI
import AppKit
struct PIIScrubberView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @State private var inputPath = ""
  @State private var outputPath = ""
  @State private var reportPath = ""
  @State private var reportFormat = "json"
  @State private var configPath = ""
  @State private var seed = "peel"
  @State private var maxSamples = 5
  @State private var enableNER = false
  @State private var toolPath = ""
  @State private var lastDetectedToolPath: String?

  @State private var report: PIIScrubberReport?
  @State private var lastReportPath: String?
  @State private var lastError: String?
  @State private var isRunning = false

  private var service: PIIScrubberService { mcpServer.piiScrubberService }

  var body: some View {
    ToolPageLayout {
      ToolSection("PII Scrubber") {
        LabeledContent("Input path") {
          TextField("/path/to/dump.sql", text: $inputPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.piiScrubber.inputPath")
        }

        LabeledContent("Output path") {
          TextField("/path/to/scrubbed.sql", text: $outputPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.piiScrubber.outputPath")
        }

        LabeledContent("Report path (optional)") {
          TextField("/path/to/report.json", text: $reportPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.piiScrubber.reportPath")
        }

        LabeledContent("Report format") {
          Picker("Report format", selection: $reportFormat) {
            Text("json").tag("json")
            Text("text").tag("text")
          }
          .pickerStyle(.segmented)
          .frame(width: 160)
          .accessibilityIdentifier("agents.piiScrubber.reportFormat")
        }

        LabeledContent("Config path (optional)") {
          TextField("/path/to/pii-scrubber.yml", text: $configPath)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 320)
            .accessibilityIdentifier("agents.piiScrubber.configPath")
        }

        Text("Formats: email, phone, ssn, credit_card, name, address, organization, generic. Actions: preserve, redact, fake, drop.")
          .font(.caption)
          .foregroundStyle(.secondary)

        LabeledContent("Seed") {
          TextField("peel", text: $seed)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .accessibilityIdentifier("agents.piiScrubber.seed")
        }

        LabeledContent("Max samples") {
          Stepper(value: $maxSamples, in: 0...50) {
            Text("\(maxSamples)")
          }
          .frame(width: 160)
          .accessibilityIdentifier("agents.piiScrubber.maxSamples")
        }

        Toggle("Enable NER", isOn: $enableNER)
          .accessibilityIdentifier("agents.piiScrubber.enableNER")

        LabeledContent("pii-scrubber path (optional)") {
          HStack(spacing: 8) {
            TextField("Auto-detect from project", text: $toolPath)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 320)
              .accessibilityIdentifier("agents.piiScrubber.toolPath")

            Button("Detect") {
              if let detected = service.suggestedToolPath() {
                toolPath = detected
                lastDetectedToolPath = detected
              }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("agents.piiScrubber.detect")
          }
        }

        HStack(spacing: 8) {
          Button(isRunning ? "Running..." : "Run Scrubber") {
            Task { await runScrubber() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRunning)
          .accessibilityIdentifier("agents.piiScrubber.run")

          if let lastDetectedToolPath {
            Text("Detected: \(lastDetectedToolPath)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let lastError {
        Text(lastError)
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let report {
        ToolSection("Audit Report") {
          HStack(spacing: 8) {
            if let lastReportPath {
              Button("Open Report") {
                openReport(at: lastReportPath)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.piiScrubber.openReport")

              Button("Save Report As…") {
                exportReport(from: lastReportPath)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("agents.piiScrubber.saveReport")
            }
          }

          if let completedAt = report.completedAt {
            Text("Completed: \(completedAt.formatted())")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          let sortedCounts = report.counts.sorted { $0.key < $1.key }
          if !sortedCounts.isEmpty {
            ForEach(sortedCounts, id: \.key) { entry in
              HStack {
                Text(entry.key)
                Spacer()
                Text("\(entry.value)")
                  .foregroundStyle(.secondary)
              }
              .font(.caption)
            }
          }

          ForEach(report.samples.keys.sorted(), id: \.self) { key in
            if let samples = report.samples[key] {
              VStack(alignment: .leading, spacing: 4) {
                Text(key)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                ForEach(samples.indices, id: \.self) { idx in
                  let sample = samples[idx]
                  Text("\(sample.original) → \(sample.replacement)")
                    .font(.caption)
                }
              }
              .padding(.top, 4)
            }
          }
        }
      }
    }
  }

  @MainActor
  private func runScrubber() async {
    isRunning = true
    lastError = nil
    report = nil
    lastReportPath = nil
    defer { isRunning = false }

    let options = PIIScrubberService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      reportPath: reportPath.isEmpty ? nil : reportPath,
      reportFormat: reportFormat.isEmpty ? nil : reportFormat,
      configPath: configPath.isEmpty ? nil : configPath,
      seed: seed.isEmpty ? nil : seed,
      maxSamples: maxSamples,
      enableNER: enableNER,
      toolPath: toolPath.isEmpty ? nil : toolPath
    )

    do {
      let result = try await service.runScrubber(options: options)
      report = result.report
      lastReportPath = result.reportPath
    } catch {
      lastError = error.localizedDescription
    }
  }

  private func openReport(at path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  private func exportReport(from path: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let destination = panel.url {
      try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
    }
  }
}
