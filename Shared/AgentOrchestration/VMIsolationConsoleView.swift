// VMIsolationConsoleView.swift

import SwiftUI

struct VMIsolationConsoleView: View {
  @Environment(VMIsolationService.self) private var service
  @State private var consoleInput = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Linux Console")
          .font(.headline)
        Spacer()
        Toggle("Console Output", isOn: Binding(
          get: { service.isConsoleOutputEnabled },
          set: { service.setConsoleOutputEnabled($0) }
        ))
        .toggleStyle(.switch)
      }

      Text("Use the serial console to interact with the netboot environment.")
        .font(.caption)
        .foregroundStyle(.secondary)

      ScrollViewReader { proxy in
        ScrollView {
          Text(service.consoleOutput)
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .id("console-output")
        }
        .frame(height: 300)
        .padding(8)
        .background(Color.black.opacity(0.9))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.tertiary))
        .onChange(of: service.consoleOutput) { _, _ in
          withAnimation {
            proxy.scrollTo("console-output", anchor: .bottom)
          }
        }
      }

      HStack(spacing: 8) {
        TextField("Send console input", text: $consoleInput)
          .textFieldStyle(.roundedBorder)
        Button("Send") {
          service.sendConsoleInput(consoleInput)
          consoleInput = ""
        }
        .buttonStyle(.bordered)
        .disabled(!service.isLinuxVMRunning)

        Button("Send Enter") {
          service.sendConsoleInput("")
        }
        .buttonStyle(.bordered)
        .disabled(!service.isLinuxVMRunning)

        Button("Clear") {
          service.clearConsoleOutput()
        }
        .buttonStyle(.bordered)
        .disabled(service.consoleOutput.isEmpty)
      }
    }
    .padding()
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
  }
}
