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
        .onAppear {
          Github.workflowJobs(from: action) {
            workflowJobs = $0.jobs
          } error: {
            print($0)
          }
        }
      
        List(workflowJobs) { workflowJob in
          Text(workflowJob.name)
        }
      }
  }
}
//
//struct SwiftUIView_Previews: PreviewProvider {
//    static var previews: some View {
//        SwiftUIView()
//    }
//}
