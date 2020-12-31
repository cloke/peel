//
//  RootView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

extension Brew {
  struct RootView: View {
    var body: some View {
      Brew.SidebarNavigationView()
    }
  }
}

struct Brew_RootView_Previews: PreviewProvider {
  static var previews: some View {
    Brew.RootView()
  }
}
