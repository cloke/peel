//
//  ActionDetailView.swift
//  ActionDetailView
//
//  Created by Cory Loken on 8/13/21.
//

import SwiftUI

struct ActionDetailView: View {
  let action: Github.Action
  
  @State private var workflowJobs = [Github.WorkflowJob]()
  
  var body: some View {
    VStack {
      Text(action.status)
        .task {
          do {
            workflowJobs = try await Github.workflowJobs(from: action).jobs
          } catch {
            print(error)
          }
        }
      
        List(workflowJobs) { workflowJob in
          VStack(alignment: .leading) {
            Text(workflowJob.name)
            Divider()
            ForEach(workflowJob.steps, id: \.name) { step in
              HStack {
                Text(step.name)
                Text(step.status)
              }
            }
          }
        }
      }
  }
}
