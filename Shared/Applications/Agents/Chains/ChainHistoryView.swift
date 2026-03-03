import SwiftUI

struct ChainHistoryView: View {
  @Bindable var agentManager: AgentManager
  var cliService: CLIService
  var sessionTracker: SessionTracker

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Chain History")
          .font(.title)
          .fontWeight(.semibold)
        Spacer()
        Text("Showing \(agentManager.chains.count) runs")
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal)
      if agentManager.chains.isEmpty {
        ContentUnavailableView {
          Label("No Chain History", systemImage: "link.circle")
        } description: {
          Text("Chain runs will appear here once you start one.")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        Spacer()
      } else {
        List {
          ForEach(agentManager.chains.sorted(by: { left, right in
            let l = left.runStartTime ?? left.results.last?.timestamp ?? Date.distantPast
            let r = right.runStartTime ?? right.results.last?.timestamp ?? Date.distantPast
            return l > r
          })) { chain in
            Button {
              agentManager.selectedChain = chain
            } label: {
              HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                  Text(chain.name).font(.headline)
                  HStack(spacing: 8) {
                    Text(chain.state.displayName)
                      .font(.subheadline)
                      .foregroundStyle(.secondary)
                    Text("•")
                    Text("\(chain.agents.count) agents")
                      .font(.subheadline)
                      .foregroundStyle(.secondary)
                    if !chain.results.isEmpty {
                      Text("•")
                      Text("\(chain.results.reduce(0) { $0 + $1.premiumCost }.premiumMultiplierString()) used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                  }
                }
                Spacer()
                VStack(alignment: .trailing) {
                  if let ts = chain.runStartTime ?? chain.results.last?.timestamp {
                    Text(ts, style: .relative)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Text(chain.results.last.map { "\($0.duration ?? "")" } ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
              }
              .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
          }
        }
        .listStyle(.inset)
      }
    }
  }
}
