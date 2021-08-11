//
//  ApplicationBrewResultView.swift
//  KitchenSync
//
//  Created by Cory Loken on 12/20/20.
//

import SwiftUI

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

struct ResultDetailView_Previews: PreviewProvider {
  static var previews: some View {
    ResultDetailView(
      resultStream: .constant(
        ["Test", "Test 1"]
      )
    )
  }
}


