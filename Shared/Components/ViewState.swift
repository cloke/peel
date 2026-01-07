//
//  ViewState.swift
//  KitchenSync
//
//  Created by Copilot on 1/7/26.
//

import SwiftUI

/// A generic enum representing the state of an async view
public enum ViewState<T> {
  case idle
  case loading
  case loaded(T)
  case error(String)
  
  public var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
  
  public var error: String? {
    if case .error(let message) = self { return message }
    return nil
  }
  
  public var value: T? {
    if case .loaded(let value) = self { return value }
    return nil
  }
}

/// A reusable error view with retry action
public struct ErrorView: View {
  let title: String
  let message: String
  let retryAction: (() -> Void)?
  
  public init(
    title: String = "Error",
    message: String,
    retryAction: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.retryAction = retryAction
  }
  
  public var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      if let retryAction {
        Button("Retry") {
          retryAction()
        }
        .buttonStyle(.bordered)
      }
    }
  }
}

/// A reusable empty state view
public struct EmptyStateView: View {
  let title: String
  let systemImage: String
  let description: String?
  
  public init(
    _ title: String,
    systemImage: String,
    description: String? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.description = description
  }
  
  public var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      if let description {
        Text(description)
      }
    }
  }
}

/// A view modifier that shows an error alert
struct ErrorAlertModifier: ViewModifier {
  @Binding var errorMessage: String?
  let title: String
  
  func body(content: Content) -> some View {
    content
      .alert(title, isPresented: .constant(errorMessage != nil)) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
  }
}

extension View {
  /// Adds an error alert that shows when errorMessage is non-nil
  func errorAlert(_ title: String = "Error", message: Binding<String?>) -> some View {
    modifier(ErrorAlertModifier(errorMessage: message, title: title))
  }
}

#Preview("Error View") {
  ErrorView(message: "Something went wrong") {
    print("Retry tapped")
  }
}

#Preview("Empty State") {
  EmptyStateView("No Items", systemImage: "tray", description: "Add some items to get started")
}
