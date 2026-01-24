//
//  CopilotModelPicker.swift
//  Peel
//
//  Created on 1/24/26.
//

import SwiftUI

/// A reusable picker for selecting CopilotModel with proper grouping.
///
/// Groups models into: Free, Claude, GPT, and Gemini sections.
///
/// Usage:
/// ```swift
/// CopilotModelPicker(selection: $model)
/// CopilotModelPicker(selection: $model, showFree: false)
/// ```
public struct CopilotModelPicker: View {
  @Binding var selection: CopilotModel
  
  /// Whether to show the Free tier models section
  var showFree: Bool
  
  /// Optional label for the picker
  var label: String?
  
  public init(
    selection: Binding<CopilotModel>,
    showFree: Bool = true,
    label: String? = nil
  ) {
    self._selection = selection
    self.showFree = showFree
    self.label = label
  }
  
  public var body: some View {
    Picker(label ?? "Model", selection: $selection) {
      if showFree {
        Section("Free") {
          ForEach(CopilotModel.allCases.filter { $0.isFree }) { model in
            ModelLabelView(model: model).tag(model)
          }
        }
      }
      
      Section("Claude") {
        ForEach(CopilotModel.allCases.filter { $0.isClaude }) { model in
          ModelLabelView(model: model).tag(model)
        }
      }
      
      Section("GPT") {
        ForEach(CopilotModel.allCases.filter { $0.isGPT && !$0.isFree }) { model in
          ModelLabelView(model: model).tag(model)
        }
      }
      
      Section("Gemini") {
        ForEach(CopilotModel.allCases.filter { $0.isGemini && !$0.isFree }) { model in
          ModelLabelView(model: model).tag(model)
        }
      }
    }
  }
}

/// A compact version of the model picker without section headers
public struct CopilotModelPickerCompact: View {
  @Binding var selection: CopilotModel
  var showFree: Bool
  
  public init(selection: Binding<CopilotModel>, showFree: Bool = true) {
    self._selection = selection
    self.showFree = showFree
  }
  
  public var body: some View {
    Picker("Model", selection: $selection) {
      ForEach(sortedModels) { model in
        ModelLabelView(model: model).tag(model)
      }
    }
  }
  
  private var sortedModels: [CopilotModel] {
    var models = [CopilotModel]()
    if showFree {
      models.append(contentsOf: CopilotModel.allCases.filter { $0.isFree })
    }
    models.append(contentsOf: CopilotModel.allCases.filter { $0.isClaude })
    models.append(contentsOf: CopilotModel.allCases.filter { $0.isGPT && !$0.isFree })
    models.append(contentsOf: CopilotModel.allCases.filter { $0.isGemini && !$0.isFree })
    return models
  }
}

#Preview("CopilotModelPicker") {
  struct PreviewWrapper: View {
    @State private var model: CopilotModel = .claudeSonnet45
    
    var body: some View {
      Form {
        CopilotModelPicker(selection: $model)
        Text("Selected: \(model.shortName)")
      }
      .frame(width: 400, height: 300)
    }
  }
  return PreviewWrapper()
}

#Preview("CopilotModelPicker - No Free") {
  struct PreviewWrapper: View {
    @State private var model: CopilotModel = .claudeSonnet45
    
    var body: some View {
      Form {
        CopilotModelPicker(selection: $model, showFree: false)
        Text("Selected: \(model.shortName)")
      }
      .frame(width: 400, height: 300)
    }
  }
  return PreviewWrapper()
}
