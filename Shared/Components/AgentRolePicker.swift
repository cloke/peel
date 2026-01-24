//
//  AgentRolePicker.swift
//  Peel
//
//  Created on 1/24/26.
//

import SwiftUI

/// A reusable picker for selecting AgentRole with descriptions and warnings.
///
/// Usage:
/// ```swift
/// AgentRolePicker(selection: $role)
/// AgentRolePicker(selection: $role, showDescription: false)
/// ```
public struct AgentRolePicker: View {
  @Binding var selection: AgentRole
  
  /// Whether to show the description text under each role
  var showDescription: Bool
  
  /// Whether to use inline picker style (shows all options)
  var useInlineStyle: Bool
  
  /// Whether to show the read-only warning
  var showReadOnlyWarning: Bool
  
  public init(
    selection: Binding<AgentRole>,
    showDescription: Bool = true,
    useInlineStyle: Bool = true,
    showReadOnlyWarning: Bool = true
  ) {
    self._selection = selection
    self.showDescription = showDescription
    self.useInlineStyle = useInlineStyle
    self.showReadOnlyWarning = showReadOnlyWarning
  }
  
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if useInlineStyle && showDescription {
        // Inline style with descriptions
        Picker("Role", selection: $selection) {
          ForEach(AgentRole.allCases) { role in
            Label {
              VStack(alignment: .leading) {
                Text(role.displayName)
                Text(role.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: role.iconName)
            }
            .tag(role)
          }
        }
        .pickerStyle(.inline)
      } else {
        // Compact style without descriptions
        Picker("Role", selection: $selection) {
          ForEach(AgentRole.allCases) { role in
            Label(role.displayName, systemImage: role.iconName)
              .tag(role)
          }
        }
      }
      
      if showReadOnlyWarning && !selection.canWrite {
        Label("Read-only: cannot edit files", systemImage: "lock.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

/// A compact role picker that just shows the label without inline expansion.
public struct AgentRolePickerCompact: View {
  @Binding var selection: AgentRole
  var showReadOnlyWarning: Bool
  
  public init(
    selection: Binding<AgentRole>,
    showReadOnlyWarning: Bool = true
  ) {
    self._selection = selection
    self.showReadOnlyWarning = showReadOnlyWarning
  }
  
  public var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Role", selection: $selection) {
        ForEach(AgentRole.allCases) { role in
          Label(role.displayName, systemImage: role.iconName)
            .tag(role)
        }
      }
      
      if showReadOnlyWarning && !selection.canWrite {
        Label("Read-only: cannot edit files", systemImage: "lock.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
  }
}

#Preview("AgentRolePicker - Inline") {
  struct PreviewWrapper: View {
    @State private var role: AgentRole = .implementer
    
    var body: some View {
      Form {
        Section("Role") {
          AgentRolePicker(selection: $role)
        }
      }
      .frame(width: 400, height: 400)
    }
  }
  return PreviewWrapper()
}

#Preview("AgentRolePicker - Compact") {
  struct PreviewWrapper: View {
    @State private var role: AgentRole = .reviewer
    
    var body: some View {
      Form {
        AgentRolePickerCompact(selection: $role)
      }
      .frame(width: 400, height: 200)
    }
  }
  return PreviewWrapper()
}
