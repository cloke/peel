//
//  FileListItemView.swift
//
//
//  Created by Cory Loken on 6/12/22.
//

import SwiftUI

@available(macOS 12, *)
struct FileListItemView: View {
  @Environment(Model.Repository.self) var repository
  var file: FileDescriptor
  @State private var toggleState: Bool = false
  
  init(file: FileDescriptor, toggleState: Bool) {
    self.file = file
    self.toggleState = toggleState
  }
  
  var body: some View {
    HStack {
      Toggle(isOn: $toggleState) { EmptyView() }
        .onChange(of: toggleState) { _, status in
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
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
  
  func icon(from path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "md", "txt", "rtf":
      return "doc.text"
    case "swift":
      return "swift"
    case "png", "jpg", "jpeg", "gif", "heic", "svg":
      return "photo"
    case "json", "yml", "yaml", "xml":
      return "curlybraces"
    case "zip", "gz", "tar", "tgz":
      return "archivebox"
    case "":
      return "doc"
    default:
      return "doc"
    }
  }
}
