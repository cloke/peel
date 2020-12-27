//
//  ApplicationBrewResultView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

extension Brew {
  struct ResultDetailView: View {
    @Binding var resultStream: [String]
    
    var body: some View {
      LazyVStack {
        ForEach(resultStream, id: \.self) { result in
          Text(result)
        }
      }
    }
  }
}

struct Brew_ResultDetailView_Previews: PreviewProvider {
  static var previews: some View {
    Brew.ResultDetailView(
      resultStream: .constant(
        ["Test", "Test 1"]
      )
    )
  }
}


