//
//  CloneRepositoryView.swift
//
//
//  Created by Cory Loken on 5/9/21.
//

import SwiftUI

#if os(macOS)
public struct CloneRepositoryView: View {
  @State private var viewModel: ViewModel = .shared
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
              Task {
                do {
                  let repository = try await Commands.clone(with: cloneUrl, to: destination)
                  isCloning = false
                  viewModel.repositories.append(repository)
                  viewModel.selectedRepository = repository
                } catch {
                  print("Handle ", error)
                }
              }
            }
          } label: { Text("Clone") }
        }
      }
    }
  }
}
#endif
