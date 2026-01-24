//
//  FormSheet.swift
//  Peel
//
//  Created on 1/24/26.
//

import SwiftUI

/// A reusable sheet with form styling and standard cancel/confirm toolbar.
///
/// Usage:
/// ```swift
/// FormSheet(
///   title: "New Item",
///   confirmText: "Create",
///   isConfirmEnabled: !name.isEmpty,
///   onConfirm: { createItem() }
/// ) {
///   TextField("Name", text: $name)
///   Picker("Type", selection: $type) { ... }
/// }
/// ```
public struct FormSheet<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  
  let title: String
  let confirmText: String
  let cancelText: String
  let isConfirmEnabled: Bool
  let minWidth: CGFloat
  let minHeight: CGFloat
  let onConfirm: () -> Void
  let onCancel: (() -> Void)?
  @ViewBuilder let content: () -> Content
  
  public init(
    title: String,
    confirmText: String = "Done",
    cancelText: String = "Cancel",
    isConfirmEnabled: Bool = true,
    minWidth: CGFloat = 400,
    minHeight: CGFloat = 300,
    onConfirm: @escaping () -> Void,
    onCancel: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.confirmText = confirmText
    self.cancelText = cancelText
    self.isConfirmEnabled = isConfirmEnabled
    self.minWidth = minWidth
    self.minHeight = minHeight
    self.onConfirm = onConfirm
    self.onCancel = onCancel
    self.content = content
  }
  
  public var body: some View {
    NavigationStack {
      Form {
        content()
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(cancelText) {
            onCancel?()
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(confirmText) {
            onConfirm()
            dismiss()
          }
          .disabled(!isConfirmEnabled)
        }
      }
    }
    .frame(minWidth: minWidth, minHeight: minHeight)
  }
}

/// A variant of FormSheet that doesn't auto-dismiss on confirm.
/// Useful when the confirm action is async or might fail.
public struct FormSheetManualDismiss<Content: View>: View {
  @Environment(\.dismiss) private var dismiss
  
  let title: String
  let confirmText: String
  let cancelText: String
  let isConfirmEnabled: Bool
  let minWidth: CGFloat
  let minHeight: CGFloat
  let onConfirm: (@escaping () -> Void) -> Void
  let onCancel: (() -> Void)?
  @ViewBuilder let content: () -> Content
  
  public init(
    title: String,
    confirmText: String = "Done",
    cancelText: String = "Cancel",
    isConfirmEnabled: Bool = true,
    minWidth: CGFloat = 400,
    minHeight: CGFloat = 300,
    onConfirm: @escaping (@escaping () -> Void) -> Void,
    onCancel: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.confirmText = confirmText
    self.cancelText = cancelText
    self.isConfirmEnabled = isConfirmEnabled
    self.minWidth = minWidth
    self.minHeight = minHeight
    self.onConfirm = onConfirm
    self.onCancel = onCancel
    self.content = content
  }
  
  public var body: some View {
    NavigationStack {
      Form {
        content()
      }
      .formStyle(.grouped)
      .navigationTitle(title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(cancelText) {
            onCancel?()
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(confirmText) {
            onConfirm { dismiss() }
          }
          .disabled(!isConfirmEnabled)
        }
      }
    }
    .frame(minWidth: minWidth, minHeight: minHeight)
  }
}

#Preview("FormSheet") {
  struct PreviewWrapper: View {
    @State private var name = ""
    @State private var showSheet = true
    
    var body: some View {
      Button("Show Sheet") { showSheet = true }
        .sheet(isPresented: $showSheet) {
          FormSheet(
            title: "New Item",
            confirmText: "Create",
            isConfirmEnabled: !name.isEmpty,
            onConfirm: { print("Created: \(name)") }
          ) {
            TextField("Name", text: $name)
          }
        }
    }
  }
  return PreviewWrapper()
}
