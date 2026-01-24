//
//  ModelLabelView.swift
//  KitchenSync
//
//  Created on 1/24/26.
//

import SwiftUI

struct ModelLabelView: View {
  let model: CopilotModel

  var body: some View {
    HStack(spacing: 8) {
      Text(model.displayName)
      Spacer(minLength: 8)
      Text(model.costLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
