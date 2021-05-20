//
//  SettingsView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/27/20.
//

import SwiftUI
import Git

struct SettingsView: View {
  @ObservedObject private var gitViewModel = ViewModel()// = .shared
  
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

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView()
  }
}
