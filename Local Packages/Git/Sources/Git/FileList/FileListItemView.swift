//
//  FileListItemView.swift
//  
//
//  Created by Cory Loken on 6/12/22.
//

import SwiftUI

@available(macOS 12, *)
struct FileListItemView: View {
  @EnvironmentObject var repository: Model.Repository
  var file: FileDescriptor
  @State private var toggleState: Bool = false
  
  init(file: FileDescriptor, toggleState: Bool) {
    self.file = file
    self.toggleState = toggleState
  }
  
  var body: some View {
    HStack {
      Toggle(isOn: $toggleState) { EmptyView() }
        .onChange(of: toggleState) { status in
          Task {
            #if canImport(AppKit)
            try? await status ?
            Commands.add(to: repository, path: file.path) :
            Commands.reset(path: file.path, on: repository)
            #endif
          }
        }
      Label(file.path, systemImage: icon(from: file.path))
        .truncationMode(.head)
      Spacer()
      Text(file.status.rawValue.replacingOccurrences(of: ".", with: ""))
        .bold()
    }
  }
  
  func icon(from path: String) -> String {
    switch (path as NSString).pathExtension {
    case "md":
      return "doc"
    default:
      return (path as NSString).pathExtension
    }
  }
}

//struct FileListItemView_Previews: PreviewProvider {
//  static var previews: some View {
//    FileListItemView()
//  }
//}


