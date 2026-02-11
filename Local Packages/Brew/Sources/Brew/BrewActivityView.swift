//
//  BrewActivityView.swift
//  Brew
//
//  Created on 1/30/26.
//

import Charts
import SwiftUI
import PeelUI

// MARK: - Data Model

struct BrewInstallRecord: Identifiable {
  let id = UUID()
  let name: String
  let version: String
  let installedDate: Date
  let installedOnRequest: Bool
  let pouredFromBottle: Bool
}

struct WeeklyInstallPoint: Identifiable {
  let id = UUID()
  let weekStart: Date
  let directCount: Int
  let dependencyCount: Int
  var totalCount: Int { directCount + dependencyCount }
}

// MARK: - Data Loading

private func cellarPath() -> String {
  let paths = [
    "/opt/homebrew/Cellar",   // Apple Silicon
    "/usr/local/Cellar"        // Intel
  ]
  for path in paths {
    if FileManager.default.fileExists(atPath: path) {
      return path
    }
  }
  return paths[0]
}

private func loadInstallRecords() async throws -> [BrewInstallRecord] {
  let cellar = cellarPath()
  let fm = FileManager.default
  
  guard let formulas = try? fm.contentsOfDirectory(atPath: cellar) else {
    return []
  }
  
  var records = [BrewInstallRecord]()
  
  for formula in formulas {
    let formulaPath = "\(cellar)/\(formula)"
    guard let versions = try? fm.contentsOfDirectory(atPath: formulaPath) else { continue }
    
    for version in versions {
      let receiptPath = "\(formulaPath)/\(version)/INSTALL_RECEIPT.json"
      guard fm.fileExists(atPath: receiptPath),
            let data = fm.contents(atPath: receiptPath) else { continue }
      
      do {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        
        let time = json["time"] as? TimeInterval ?? 0
        guard time > 0 else { continue }
        
        let record = BrewInstallRecord(
          name: formula,
          version: version,
          installedDate: Date(timeIntervalSince1970: time),
          installedOnRequest: json["installed_on_request"] as? Bool ?? false,
          pouredFromBottle: json["poured_from_bottle"] as? Bool ?? false
        )
        records.append(record)
      } catch {
        continue
      }
    }
  }
  
  return records.sorted { $0.installedDate < $1.installedDate }
}

private func buildWeeklyPoints(from records: [BrewInstallRecord]) -> [WeeklyInstallPoint] {
  guard !records.isEmpty else { return [] }
  
  let calendar = Calendar.current
  
  // Group records by week
  var weekBuckets = [Date: (direct: Int, dependency: Int)]()
  
  for record in records {
    guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: record.installedDate)?.start else { continue }
    var bucket = weekBuckets[weekStart, default: (direct: 0, dependency: 0)]
    if record.installedOnRequest {
      bucket.direct += 1
    } else {
      bucket.dependency += 1
    }
    weekBuckets[weekStart] = bucket
  }
  
  return weekBuckets.map { (weekStart, counts) in
    WeeklyInstallPoint(weekStart: weekStart, directCount: counts.direct, dependencyCount: counts.dependency)
  }.sorted { $0.weekStart < $1.weekStart }
}

// MARK: - Activity Data

private struct ActivityData {
  let records: [BrewInstallRecord]
  let weeklyPoints: [WeeklyInstallPoint]
  let directCount: Int
  let dependencyCount: Int
  
  var totalCount: Int { directCount + dependencyCount }
  
  var oldestInstall: Date? { records.first?.installedDate }
  var newestInstall: Date? { records.last?.installedDate }
  
  var bottlePercentage: Int {
    guard totalCount > 0 else { return 0 }
    let bottleCount = records.filter(\.pouredFromBottle).count
    return Int(Double(bottleCount) / Double(totalCount) * 100)
  }
}

// MARK: - View

public struct BrewActivityView: View {
  public init() {}
  
  public var body: some View {
    AsyncContentView(
      load: {
        let records = try await loadInstallRecords()
        let weekly = buildWeeklyPoints(from: records)
        return ActivityData(
          records: records,
          weeklyPoints: weekly,
          directCount: records.filter(\.installedOnRequest).count,
          dependencyCount: records.filter { !$0.installedOnRequest }.count
        )
      },
      isEmpty: { $0.records.isEmpty },
      content: { data in
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            summarySection(data)
            installTimelineChart(data)
            recentInstallsSection(data)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      },
      loadingView: { ProgressView("Scanning Cellar...") },
      emptyView: { EmptyStateView("No Packages", systemImage: "chart.bar") }
    )
    .navigationTitle("Homebrew Activity")
  }
  
  // MARK: - Summary

  @ViewBuilder
  private func summarySection(_ data: ActivityData) -> some View {
    SectionCard("Overview") {
      HStack(spacing: 20) {
        statBadge(value: "\(data.totalCount)", label: "Total", icon: "shippingbox.fill", color: .blue)
        statBadge(value: "\(data.directCount)", label: "Direct", icon: "hand.point.right.fill", color: .green)
        statBadge(value: "\(data.dependencyCount)", label: "Dependencies", icon: "link", color: .orange)
        statBadge(value: "\(data.bottlePercentage)%", label: "Bottles", icon: "waterbottle.fill", color: .purple)
      }
      
      if let oldest = data.oldestInstall, let newest = data.newestInstall {
        HStack(spacing: 8) {
          Image(systemName: "calendar")
            .foregroundColor(.secondary)
          Text("From \(oldest, format: .dateTime.month().year()) to \(newest, format: .dateTime.month().year())")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
      }
    }
  }
  
  @ViewBuilder
  private func statBadge(value: String, label: String, icon: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Image(systemName: icon)
        .font(.system(size: 16))
        .foregroundColor(color)
      Text(value)
        .font(.system(size: 20, weight: .semibold, design: .rounded))
      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }
  
  // MARK: - Timeline Chart

  @ViewBuilder
  private func installTimelineChart(_ data: ActivityData) -> some View {
    SectionCard("Installs Over Time") {
      if data.weeklyPoints.isEmpty {
        Text("Not enough data for timeline")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Chart(data.weeklyPoints) { point in
          BarMark(
            x: .value("Week", point.weekStart, unit: .weekOfYear),
            y: .value("Count", point.directCount)
          )
          .foregroundStyle(Color.green)
          
          BarMark(
            x: .value("Week", point.weekStart, unit: .weekOfYear),
            y: .value("Count", point.dependencyCount)
          )
          .foregroundStyle(Color.orange)
        }
        .chartForegroundStyleScale([
          "Direct": Color.green,
          "Dependency": Color.orange
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
          AxisMarks(values: .stride(by: .month)) {
            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
            AxisGridLine()
          }
        }
        .frame(height: 200)
      }
    }
  }
  
  // MARK: - Recent Installs

  @ViewBuilder
  private func recentInstallsSection(_ data: ActivityData) -> some View {
    let recent = Array(data.records.suffix(15).reversed())
    
    SectionCard("Recent Installs") {
      ForEach(recent) { record in
        HStack(spacing: 8) {
          Image(systemName: record.installedOnRequest ? "hand.point.right.fill" : "link")
            .font(.system(size: 11))
            .foregroundColor(record.installedOnRequest ? .green : .orange)
            .frame(width: 16)
          
          Text(record.name)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
          
          Text(record.version)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          
          Spacer()
          
          Text(record.installedDate, format: .dateTime.month(.abbreviated).day().year())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}

#Preview {
  BrewActivityView()
    .frame(width: 600, height: 700)
}
