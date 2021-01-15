//
//  SearchBarView.swift
//
//  Created by Cory Loken on 7/13/20.
//

import SwiftUI

struct SearchBarView: View {
  @Binding var searchText: String
  @Binding var isSearching: Bool
  @State private var isEditingSearch = false
  
  var body: some View {
    TextField("Search...", text: $searchText)
      .padding(7)
      .padding(.horizontal, 25)
      .cornerRadius(8)
      .overlay(
        HStack {
          Group {
            if $isSearching.wrappedValue {
              ProgressView()
            } else {
              Image(systemName: "magnifyingglass")
            }
          }
          .foregroundColor(.gray)
          .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 8)
          
          if isEditingSearch {
            Button {
              isEditingSearch = false
              searchText = ""
            } label: {
              Image(systemName: "multiply.circle.fill")
                .foregroundColor(.gray)
                .padding(.trailing, 8)
            }
          }
        }
    )
      .onTapGesture {
        self.isEditingSearch = true
    }
  }
}

struct SearchBarView_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      SearchBarView(searchText: .constant("Phillip j"), isSearching: .constant(true))
      SearchBarView(searchText: .constant("Phillip j"), isSearching: .constant(false))
    }
    .padding()
  }
}
