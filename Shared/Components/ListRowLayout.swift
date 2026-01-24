//
//  ListRowLayout.swift
//  Peel
//
//  Created on 1/24/26.
//

import SwiftUI

/// A standardized list row layout with icon, title, subtitle, and accessory.
///
/// Usage:
/// ```swift
/// ListRowLayout(
///   title: "Repository",
///   subtitle: "main branch",
///   icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) },
///   accessory: { Text("5").foregroundStyle(.secondary) }
/// )
/// ```
public struct ListRowLayout<Icon: View, Accessory: View>: View {
  let title: String
  let subtitle: String?
  let spacing: CGFloat
  let iconWidth: CGFloat?
  @ViewBuilder let icon: () -> Icon
  @ViewBuilder let accessory: () -> Accessory
  
  public init(
    title: String,
    subtitle: String? = nil,
    spacing: CGFloat = 12,
    iconWidth: CGFloat? = nil,
    @ViewBuilder icon: @escaping () -> Icon,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.title = title
    self.subtitle = subtitle
    self.spacing = spacing
    self.iconWidth = iconWidth
    self.icon = icon
    self.accessory = accessory
  }
  
  public var body: some View {
    HStack(spacing: spacing) {
      if let iconWidth {
        icon()
          .frame(width: iconWidth)
      } else {
        icon()
      }
      
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .fontWeight(.medium)
        if let subtitle {
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      accessory()
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Convenience initializers

extension ListRowLayout where Accessory == EmptyView {
  /// Creates a row without an accessory view.
  public init(
    title: String,
    subtitle: String? = nil,
    spacing: CGFloat = 12,
    iconWidth: CGFloat? = nil,
    @ViewBuilder icon: @escaping () -> Icon
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      spacing: spacing,
      iconWidth: iconWidth,
      icon: icon,
      accessory: { EmptyView() }
    )
  }
}

extension ListRowLayout where Icon == AnyView {
  /// Creates a row with a system image icon.
  public init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    iconColor: Color = .primary,
    spacing: CGFloat = 12,
    @ViewBuilder accessory: @escaping () -> Accessory
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      spacing: spacing,
      iconWidth: nil,
      icon: {
        AnyView(
          Image(systemName: systemImage)
            .foregroundStyle(iconColor)
        )
      },
      accessory: accessory
    )
  }
}

extension ListRowLayout where Icon == AnyView, Accessory == EmptyView {
  /// Creates a simple row with just a system image and title.
  public init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    iconColor: Color = .primary
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      spacing: 12,
      iconWidth: nil,
      icon: {
        AnyView(
          Image(systemName: systemImage)
            .foregroundStyle(iconColor)
        )
      },
      accessory: { EmptyView() }
    )
  }
}

extension ListRowLayout where Icon == AnyView, Accessory == Text {
  /// Creates a row with a system image and text accessory.
  public init(
    title: String,
    subtitle: String? = nil,
    systemImage: String,
    iconColor: Color = .primary,
    badge: String
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      spacing: 12,
      iconWidth: nil,
      icon: {
        AnyView(
          Image(systemName: systemImage)
            .foregroundStyle(iconColor)
        )
      },
      accessory: {
        Text(badge)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    )
  }
}

// MARK: - Status Row variant

/// A list row with a status indicator (colored circle or progress).
public struct StatusListRow<Accessory: View>: View {
  let title: String
  let subtitle: String?
  let status: Status
  @ViewBuilder let accessory: () -> Accessory
  
  public enum Status {
    case idle
    case inProgress
    case success
    case warning
    case error
    
    var color: Color {
      switch self {
      case .idle: return .secondary
      case .inProgress: return .blue
      case .success: return .green
      case .warning: return .orange
      case .error: return .red
      }
    }
    
    var icon: String {
      switch self {
      case .idle: return "circle"
      case .inProgress: return "circle.dotted"
      case .success: return "checkmark.circle.fill"
      case .warning: return "exclamationmark.triangle.fill"
      case .error: return "xmark.circle.fill"
      }
    }
  }
  
  public init(
    title: String,
    subtitle: String? = nil,
    status: Status,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }
  ) {
    self.title = title
    self.subtitle = subtitle
    self.status = status
    self.accessory = accessory
  }
  
  public var body: some View {
    ListRowLayout(
      title: title,
      subtitle: subtitle,
      icon: {
        if status == .inProgress {
          ProgressView()
            .scaleEffect(0.7)
            .frame(width: 16, height: 16)
        } else {
          Image(systemName: status.icon)
            .foregroundStyle(status.color)
        }
      },
      accessory: accessory
    )
  }
}

#Preview("ListRowLayout") {
  List {
    ListRowLayout(
      title: "Repository",
      subtitle: "main branch",
      icon: {
        Image(systemName: "folder.fill")
          .foregroundStyle(.blue)
      },
      accessory: {
        Text("5")
          .foregroundStyle(.secondary)
      }
    )
    
    ListRowLayout(
      title: "Simple Row",
      systemImage: "star.fill",
      iconColor: .yellow
    )
    
    ListRowLayout(
      title: "With Badge",
      subtitle: "Updated today",
      systemImage: "bell.fill",
      iconColor: .orange,
      badge: "3"
    )
  }
  .frame(width: 300, height: 200)
}

#Preview("StatusListRow") {
  List {
    StatusListRow(title: "Idle Task", status: .idle)
    StatusListRow(title: "Running Task", subtitle: "In progress...", status: .inProgress)
    StatusListRow(title: "Completed Task", status: .success)
    StatusListRow(title: "Warning Task", subtitle: "Needs attention", status: .warning)
    StatusListRow(title: "Failed Task", status: .error)
  }
  .frame(width: 300, height: 300)
}
