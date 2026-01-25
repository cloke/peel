//
//  Confirmations.swift
//  PeelUI
//
//  Created on 1/24/26.
//

import SwiftUI

public struct ConfirmAction: Identifiable {
  public let id = UUID()
  public let title: String
  public let message: String?
  public let confirmLabel: String
  public let cancelLabel: String
  public let role: ButtonRole?
  public let onConfirm: () -> Void

  public init(
    title: String,
    message: String? = nil,
    confirmLabel: String = "Confirm",
    cancelLabel: String = "Cancel",
    role: ButtonRole? = .destructive,
    onConfirm: @escaping () -> Void
  ) {
    self.title = title
    self.message = message
    self.confirmLabel = confirmLabel
    self.cancelLabel = cancelLabel
    self.role = role
    self.onConfirm = onConfirm
  }
}

public extension View {
  func confirmAlert(
    _ title: String,
    isPresented: Binding<Bool>,
    confirmLabel: String = "Confirm",
    confirmRole: ButtonRole? = .destructive,
    cancelLabel: String = "Cancel",
    confirmIdentifier: String? = nil,
    cancelIdentifier: String? = nil,
    message: String? = nil,
    onConfirm: @escaping () -> Void
  ) -> some View {
    alert(title, isPresented: isPresented) {
      if let cancelIdentifier {
        Button(cancelLabel, role: .cancel) {
          isPresented.wrappedValue = false
        }
        .accessibilityIdentifier(cancelIdentifier)
      } else {
        Button(cancelLabel, role: .cancel) {
          isPresented.wrappedValue = false
        }
      }
      if let confirmIdentifier {
        Button(confirmLabel, role: confirmRole) {
          onConfirm()
          isPresented.wrappedValue = false
        }
        .accessibilityIdentifier(confirmIdentifier)
      } else {
        Button(confirmLabel, role: confirmRole) {
          onConfirm()
          isPresented.wrappedValue = false
        }
      }
    } message: {
      Group {
        if let message {
          Text(message)
        }
      }
    }
  }

  func confirmDialog(
    _ title: String,
    isPresented: Binding<Bool>,
    confirmLabel: String = "Confirm",
    confirmRole: ButtonRole? = .destructive,
    cancelLabel: String = "Cancel",
    confirmIdentifier: String? = nil,
    cancelIdentifier: String? = nil,
    message: String? = nil,
    onConfirm: @escaping () -> Void
  ) -> some View {
    confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
      if let confirmIdentifier {
        Button(confirmLabel, role: confirmRole) {
          onConfirm()
          isPresented.wrappedValue = false
        }
        .accessibilityIdentifier(confirmIdentifier)
      } else {
        Button(confirmLabel, role: confirmRole) {
          onConfirm()
          isPresented.wrappedValue = false
        }
      }
      if let cancelIdentifier {
        Button(cancelLabel, role: .cancel) {
          isPresented.wrappedValue = false
        }
        .accessibilityIdentifier(cancelIdentifier)
      } else {
        Button(cancelLabel, role: .cancel) {
          isPresented.wrappedValue = false
        }
      }
    } message: {
      Group {
        if let message {
          Text(message)
        }
      }
    }
  }

  func confirmAlert(_ action: Binding<ConfirmAction?>) -> some View {
    let current = action.wrappedValue
    let isPresented = Binding(
      get: { action.wrappedValue != nil },
      set: { show in if !show { action.wrappedValue = nil } }
    )
    return confirmAlert(
      current?.title ?? "Confirm",
      isPresented: isPresented,
      confirmLabel: current?.confirmLabel ?? "Confirm",
      confirmRole: current?.role,
      cancelLabel: current?.cancelLabel ?? "Cancel",
      message: current?.message
    ) {
      current?.onConfirm()
      action.wrappedValue = nil
    }
  }

  func confirmDialog(_ action: Binding<ConfirmAction?>) -> some View {
    let current = action.wrappedValue
    let isPresented = Binding(
      get: { action.wrappedValue != nil },
      set: { show in if !show { action.wrappedValue = nil } }
    )
    return confirmDialog(
      current?.title ?? "Confirm",
      isPresented: isPresented,
      confirmLabel: current?.confirmLabel ?? "Confirm",
      confirmRole: current?.role,
      cancelLabel: current?.cancelLabel ?? "Cancel",
      message: current?.message
    ) {
      current?.onConfirm()
      action.wrappedValue = nil
    }
  }
}
