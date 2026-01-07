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
    }
    .padding()
    .frame(minWidth: 400, minHeight: 400)
  }
}

#Preview {
  SettingsView()
}
