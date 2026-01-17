//
//  SettingsView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI
import Git

struct SettingsView: View {
  @State private var gitViewModel = ViewModel()
  
  var body: some View {
    Form {
      Button("Reset Git") {
        gitViewModel.resetSettings()
      }
      .help("Removes all references to repositories. Does not affect actual repository.")

      Section("About") {
        Text("Work in progress. If this tool helps you, donations help move it along.")
          .font(.caption)
          .foregroundStyle(.secondary)

        Link("GitHub: crunchybananas", destination: URL(string: "https://github.com/crunchybananas")!)
      }
    }
    .padding()
    .frame(minWidth: 400, minHeight: 400)
  }
}

#Preview {
  SettingsView()
}
