//
//  PIIScrubberView.swift
//  KitchenSync
//
//  Created on 1/20/26.
//

import SwiftUI

#if os(macOS)
struct PIIScrubberView: View {
  @Environment(MCPServerService.self) private var mcpServer
  @State private var inputPath = ""
  @State private var outputPath = ""
  @State private var reportPath = ""
  @State private var reportFormat = "json"
  @State private var seed = "peel"
  @State private var maxSamples = 5
  @State private var enableNER = false
  @State private var toolPath = ""
  @State private var lastDetectedToolPath: String?

  @State private var report: PIIScrubberReport?
  @State private var lastError: String?
  @State private var isRunning = false

  private var service: PIIScrubberService { mcpServer.piiScrubberService }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Text("PII Scrubber")
              .font(.headline)

            LabeledContent("Input path") {
              TextField("/path/to/dump.sql", text: $inputPath)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            }

            LabeledContent("Output path") {
              TextField("/path/to/scrubbed.sql", text: $outputPath)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            }

            LabeledContent("Report path (optional)") {
              TextField("/path/to/report.json", text: $reportPath)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
            }

            LabeledContent("Report format") {
              Picker("Report format", selection: $reportFormat) {
                Text("json").tag("json")
                Text("text").tag("text")
              }
              .pickerStyle(.segmented)
              .frame(width: 160)
            }

            LabeledContent("Seed") {
              TextField("peel", text: $seed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            }

            LabeledContent("Max samples") {
              Stepper(value: $maxSamples, in: 0...50) {
                Text("\(maxSamples)")
              }
              .frame(width: 160)
            }

            Toggle("Enable NER (placeholder)", isOn: $enableNER)

            LabeledContent("pii-scrubber path (optional)") {
              HStack(spacing: 8) {
                TextField("Auto-detect from project", text: $toolPath)
                  .textFieldStyle(.roundedBorder)
                  .frame(minWidth: 320)

                Button("Detect") {
                  if let detected = service.suggestedToolPath() {
                    toolPath = detected
                    lastDetectedToolPath = detected
                  }
                }
                .buttonStyle(.bordered)
              }
            }

            HStack(spacing: 12) {
              Button(isRunning ? "Running..." : "Run Scrubber") {
                Task { await runScrubber() }
              }
              .buttonStyle(.borderedProminent)
              .disabled(isRunning)

              if let lastDetectedToolPath {
                Text("Detected: \(lastDetectedToolPath)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        if let lastError {
          Text(lastError)
            .font(.caption)
            .foregroundStyle(.red)
        }

        if let report {
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              Text("Audit Report")
                .font(.headline)

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
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
  }

  @MainActor
  private func runScrubber() async {
    isRunning = true
    lastError = nil
    report = nil
    defer { isRunning = false }

    let options = PIIScrubberService.Options(
      inputPath: inputPath,
      outputPath: outputPath,
      reportPath: reportPath.isEmpty ? nil : reportPath,
      reportFormat: reportFormat.isEmpty ? nil : reportFormat,
      seed: seed.isEmpty ? nil : seed,
      maxSamples: maxSamples,
      enableNER: enableNER,
      toolPath: toolPath.isEmpty ? nil : toolPath
    )

    do {
      let result = try await service.runScrubber(options: options)
      report = result.report
    } catch {
      lastError = error.localizedDescription
    }
  }
}
#endif
