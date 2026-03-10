import Foundation

enum Framework: String, CaseIterable, Sendable {
  case ember
  case react
  case vue
  case rails
  case swiftUI
  case unknown
}

struct FrameworkDetectionResult: Sendable {
  let primary: Framework
  let secondary: [Framework]
  let directiveContent: String
}

struct FrameworkDetector {
  static func detect(repoPath: String) -> FrameworkDetectionResult {
    var detected: [Framework] = []

    // SwiftUI: check for Package.swift
    let packageSwiftPath = URL(fileURLWithPath: repoPath).appendingPathComponent("Package.swift").path
    if FileManager.default.fileExists(atPath: packageSwiftPath) {
      detected.append(.swiftUI)
    }

    // JavaScript frameworks: parse package.json
    let packageJSONPath = URL(fileURLWithPath: repoPath).appendingPathComponent("package.json")
    if let data = try? Data(contentsOf: packageJSONPath),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      let deps = (json["dependencies"] as? [String: Any] ?? [:]).keys
      let devDeps = (json["devDependencies"] as? [String: Any] ?? [:]).keys
      let allDeps = Set(deps).union(devDeps)

      let emberMarkers: Set<String> = [
        "ember-source", "ember-cli", "ember-data",
        "@glimmer/component", "@glimmer/tracking"
      ]
      let isEmber = !emberMarkers.intersection(allDeps).isEmpty
        || allDeps.contains(where: { $0.hasPrefix("@ember/") })
      if isEmber { detected.append(.ember) }

      if allDeps.contains("react") || allDeps.contains("react-dom") {
        detected.append(.react)
      }

      if allDeps.contains("vue") {
        detected.append(.vue)
      }
    }

    // Rails: parse Gemfile
    let gemfilePath = URL(fileURLWithPath: repoPath).appendingPathComponent("Gemfile").path
    if let gemfileContent = try? String(contentsOfFile: gemfilePath, encoding: .utf8) {
      if gemfileContent.contains("\"rails\"") || gemfileContent.contains("'rails'") {
        detected.append(.rails)
      }
    }

    let primary = detected.first ?? .unknown
    let secondary = Array(detected.dropFirst())
    let directives = directiveContent(for: primary)

    return FrameworkDetectionResult(primary: primary, secondary: secondary, directiveContent: directives)
  }

  private static func directiveContent(for framework: Framework) -> String {
    switch framework {
    case .ember:
      // Ember directives are maintained in LocalChatToolsHandler.emberDirectiveRules
      return ""
    case .react:
      return reactDirectives
    case .vue:
      return vueDirectives
    case .rails:
      return railsDirectives
    case .swiftUI:
      return swiftUIDirectives
    case .unknown:
      return ""
    }
  }

  static let reactDirectives = """
  REACT PROJECT — CODING DIRECTIVES

  Use functional components. Do not use class components.
  Prefer hooks: useState, useEffect, useCallback, useMemo, useRef.
  Keep components small and single-purpose.
  Use TypeScript. Define prop types with interfaces, not PropTypes.
  Prefer named exports over default exports for components.
  Co-locate tests next to the component file (e.g., Button.test.tsx).
  Avoid prop drilling — prefer context or state management libs for deep state.
  Memoize expensive computations with useMemo; stabilize callbacks with useCallback.
  Avoid inline object/array literals in JSX props to prevent needless re-renders.
  Use keys that are stable and unique (not array indexes) in lists.
  """

  static let vueDirectives = """
  VUE PROJECT — CODING DIRECTIVES

  Use Composition API with <script setup> syntax. Avoid Options API for new code.
  Use ref() for primitive state and reactive() for object/array state.
  Define component props with defineProps<>() using TypeScript generics.
  Emit events with defineEmits and document each emitted event.
  Extract reusable logic into composables (use* prefix, e.g., useAuth).
  Keep templates clean — move complex logic to computed properties or methods.
  Use v-model for two-way bindings; prefer component v-model over manual emit.
  Avoid direct DOM manipulation; rely on Vue's reactivity system.
  Use <Suspense> and async components for code splitting.
  Co-locate styles with components using <style scoped>.
  """

  static let railsDirectives = """
  RAILS PROJECT — CODING DIRECTIVES

  Follow Rails conventions: MVC, RESTful routes, convention over configuration.
  Keep controllers thin — move business logic to service objects or models.
  Use service objects (app/services/) for complex, multi-step operations.
  Prefer named scopes over raw SQL in models.
  Use strong parameters in controllers; never mass-assign without permit.
  Write system tests for critical user flows; unit tests for models and services.
  Avoid callbacks in models for side-effects; prefer explicit service calls.
  Use background jobs (Sidekiq/GoodJob) for slow or external operations.
  Keep views logic-free; use presenters or decorators for display logic.
  Run `rails db:migrate` and commit schema.rb alongside migration files.
  """

  static let swiftUIDirectives = """
  SWIFTUI / SWIFT PROJECT — CODING DIRECTIVES

  Use @Observable not ObservableObject. Remove @Published when migrating.
  Annotate ViewModels with @MainActor to ensure UI updates on main thread.
  Use NavigationStack not NavigationView.
  Use structured concurrency: async/await and Task. Avoid DispatchQueue.main.async.
  Do not use Combine for new code; use Task and AsyncStream instead.
  Use 2-space indentation throughout.
  Prefer value types (structs, enums) over classes where possible.
  Conform new types to Sendable for Swift 6 strict concurrency.
  Use actors for shared mutable state accessed from multiple tasks.
  Never force-unwrap (!) in production code; use guard let or if let.
  """
}
