//
//  Git_FileListView.swift
//  KitchenSink
//
//  Created by Cory Loken on 12/28/20.
//

import SwiftUI

extension Color {
  var isDarkColor: Bool {
    var r, g, b, a: CGFloat
    (r, g, b, a) = (0, 0, 0, 0)
    NSColor(self).usingColorSpace(.extendedSRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
    let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return  lum < 0.50
  }
}

struct FileListItemView: View {
  var path: String
  @State var toggleState: Bool
  
  var body: some View {
    HStack {
      Toggle(isOn: $toggleState) { EmptyView() }
        .onChange(of: toggleState) {
          $0 ? ViewModel.shared.add(path: path) : ViewModel.shared.unadd(path: path)
        }
      Text(path)
        .truncationMode(.head)
        .lineLimit(1)
      Spacer()
    }
  }
}

struct FileListView: View {
  @State private var commitMessage: String = ""
  @State private var changes = [FileStatus]()
  @State private var diff = Diff()
  
  var body: some View {
    NavigationView {
      List {
        TextEditor(text: $commitMessage)
          .frame(height: 100)
        Button("Commit Changes") {
          ViewModel.shared.commit(message: commitMessage) { _ in
            commitMessage = ""
            ViewModel.shared.status() { changes = $0 }
          }
        }
        ForEach(changes) { change in
          FileListItemView(path: change.path, toggleState: change.status != "??" ? false : true)
            .contentShape(Rectangle())
            .background(color(string: change.status))
            .foregroundColor(color(string: change.status).isDarkColor == true ? .white : .black)
            .onTapGesture {
              DispatchQueue.main.async {
                let str = change.path
                  .replacingOccurrences(of: " ", with: "\\ ")
//                  .replacingOccurrences(of: "\"", with: "")
                
                ViewModel.shared.diff(path: str) { diff = $0 }
              }
            }
            .contextMenu {
              Button {}
                label: {
                  Text("Ignore")
                  Image(systemName: "pencil.slash")
                }
              Button {}
                label: {
                  Text("Move to trash")
                  Image(systemName: "trash")
                }
              Button {
                let str = change.path
                  .replacingOccurrences(of: " ", with: "\\ ")
//                  .replacingOccurrences(of: "\"", with: "")
                ViewModel.shared.restore(path: str) { _ in
                  ViewModel.shared.status() { changes = $0 }
                }
              }
              label: {
                Text("Revert file")
                Image(systemName: "arrow.uturn.backward")
              }
            }
        }
      }
      DiffView(diff: diff)
    }
    .onAppear {
      ViewModel.shared.status() { changes = $0 }
    }
  }
  
  func color(string: String) -> Color {
    switch string {
    case let str where str.starts(with: "AM"): return .blue
    case let str where str.starts(with: ".A"): return Git.green
    case let str where str.starts(with: ".M"): return .yellow
    case let str where str.starts(with: "??"): return .purple
    default: return .clear
    }
  }
}

struct FileListView_Previews: PreviewProvider {
  static var previews: some View {
    FileListView()
  }
}
