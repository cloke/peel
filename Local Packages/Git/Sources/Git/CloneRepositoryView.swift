//
//  CloneRepositoryView.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

import SwiftUI

public struct CloneRepositoryView: View {
  @StateObject private var viewModel: ViewModel = .shared
  @State private var cloneUrl = ""
  @Binding var isCloning: Bool
  
  public init(isCloning: Binding<Bool>) {
    self._isCloning = isCloning
  }
  
  public var body: some View {
    Form {
      Section(header: Text("Repository Url")) {
        TextField("", text: $cloneUrl)
        HStack {
          Button { isCloning = false }
            label: { Text("Cancel") }
          Spacer()
          Button {
            viewModel.open() { destination in
              Commands.clone(with: cloneUrl, to: destination) {
                isCloning = false
                  viewModel.repositories.append($0)
                  viewModel.selectedRepository = $0
              }
            }
          } label: { Text("Clone") }
        }
      }
    }
  }
}
