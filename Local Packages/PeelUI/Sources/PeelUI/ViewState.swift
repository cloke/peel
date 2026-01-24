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
public struct ErrorAlertModifier: ViewModifier {
  @Binding var errorMessage: String?
  let title: String
  
  public init(errorMessage: Binding<String?>, title: String) {
    self._errorMessage = errorMessage
    self.title = title
  }
  
  public func body(content: Content) -> some View {
    content
      .alert(title, isPresented: .constant(errorMessage != nil)) {
        Button("OK") { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "An unknown error occurred")
      }
  }
}

public extension View {
  /// Adds an error alert that shows when errorMessage is non-nil
  func errorAlert(_ title: String = "Error", message: Binding<String?>) -> some View {
    modifier(ErrorAlertModifier(errorMessage: message, title: title))
  }
}

// MARK: - AsyncContentView

/// A reusable view that handles async data loading with loading/error/empty/content states.
///
/// Usage:
/// ```swift
/// AsyncContentView(
///   load: { try await api.fetchItems() },
///   content: { items in ItemList(items: items) },
///   emptyView: { EmptyStateView("No Items", systemImage: "tray") }
/// )
/// .id(someId) // Triggers reload when id changes
/// ```
public struct AsyncContentView<T, Content: View, Loader: View, Empty: View>: View {
  @State private var state: ViewState<T> = .idle
  
  private let load: () async throws -> T
  private let isEmpty: (T) -> Bool
  private let content: (T) -> Content
  private let loadingView: () -> Loader
  private let emptyView: () -> Empty
  
  public init(
    load: @escaping () async throws -> T,
    isEmpty: @escaping (T) -> Bool,
    @ViewBuilder content: @escaping (T) -> Content,
    @ViewBuilder loadingView: @escaping () -> Loader,
    @ViewBuilder emptyView: @escaping () -> Empty
  ) {
    self.load = load
    self.isEmpty = isEmpty
    self.content = content
    self.loadingView = loadingView
    self.emptyView = emptyView
  }
  
  public var body: some View {
    Group {
      switch state {
      case .idle:
        Color.clear
          .task { await performLoad() }
      case .loading:
        loadingView()
      case .loaded(let data):
        if isEmpty(data) {
          emptyView()
        } else {
          content(data)
        }
      case .error(let message):
        ErrorView(message: message) {
          Task { await performLoad() }
        }
      }
    }
  }
  
  private func performLoad() async {
    state = .loading
    do {
      let data = try await load()
      state = .loaded(data)
    } catch is CancellationError {
      // Ignore cancellation - view was dismissed
    } catch {
      state = .error(error.localizedDescription)
    }
  }
  
  /// Force a reload of the data
  public func reload() async {
    await performLoad()
  }
}

// MARK: - Convenience initializers for collections

extension AsyncContentView where T: Collection, Loader == ProgressView<EmptyView, EmptyView> {
  /// Convenience initializer for loading collections with default ProgressView
  public init(
    load: @escaping () async throws -> T,
    @ViewBuilder content: @escaping (T) -> Content,
    @ViewBuilder emptyView: @escaping () -> Empty
  ) {
    self.init(
      load: load,
      isEmpty: { $0.isEmpty },
      content: content,
      loadingView: { ProgressView() },
      emptyView: emptyView
    )
  }
}

extension AsyncContentView where Loader == ProgressView<EmptyView, EmptyView> {
  /// Convenience initializer with default ProgressView
  public init(
    load: @escaping () async throws -> T,
    isEmpty: @escaping (T) -> Bool,
    @ViewBuilder content: @escaping (T) -> Content,
    @ViewBuilder emptyView: @escaping () -> Empty
  ) {
    self.init(
      load: load,
      isEmpty: isEmpty,
      content: content,
      loadingView: { ProgressView() },
      emptyView: emptyView
    )
  }
}

extension AsyncContentView where T: Collection, Empty == EmptyView, Loader == ProgressView<EmptyView, EmptyView> {
  /// Convenience initializer for collections that don't need an empty view
  public init(
    load: @escaping () async throws -> T,
    @ViewBuilder content: @escaping (T) -> Content
  ) {
    self.init(
      load: load,
      isEmpty: { $0.isEmpty },
      content: content,
      loadingView: { ProgressView() },
      emptyView: { EmptyView() }
    )
  }
}

// MARK: - AsyncContentView with loading message

extension AsyncContentView where Loader == AnyView {
  /// Convenience initializer with a custom loading message
  public init(
    loadingMessage: String,
    load: @escaping () async throws -> T,
    isEmpty: @escaping (T) -> Bool,
    @ViewBuilder content: @escaping (T) -> Content,
    @ViewBuilder emptyView: @escaping () -> Empty
  ) {
    self.init(
      load: load,
      isEmpty: isEmpty,
      content: content,
      loadingView: { AnyView(ProgressView(loadingMessage)) },
      emptyView: emptyView
    )
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

#Preview("AsyncContentView - Loading") {
  AsyncContentView(
    load: {
      try await Task.sleep(for: .seconds(60))
      return ["Item 1", "Item 2"]
    },
    content: { items in
      List(items, id: \.self) { Text($0) }
    },
    emptyView: { EmptyStateView("No Items", systemImage: "tray") }
  )
}

#Preview("AsyncContentView - Loaded") {
  AsyncContentView(
    load: { ["Item 1", "Item 2", "Item 3"] },
    content: { items in
      List(items, id: \.self) { Text($0) }
    },
    emptyView: { EmptyStateView("No Items", systemImage: "tray") }
  )
}
