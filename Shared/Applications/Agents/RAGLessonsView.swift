//
//  RAGLessonsView.swift
//  Peel
//
//  Browse and manage learned lessons for a repository.
//  Lessons capture recurring error patterns and their fixes.
//

import PeelUI
import SwiftUI

struct RAGLessonsView: View {
  let repo: MCPServerService.RAGRepoInfo
  @Bindable var mcpServer: MCPServerService
  @Environment(\.dismiss) private var dismiss
  
  @State private var lessons: [LocalRAGLesson] = []
  @State private var isLoading: Bool = true
  @State private var errorMessage: String?
  
  // Selection & editing
  @State private var selectedLessonId: String?
  @State private var lessonFilePattern: String = ""
  @State private var lessonErrorSignature: String = ""
  @State private var lessonFixDescription: String = ""
  @State private var lessonFixCode: String = ""
  @State private var lessonConfidence: Float = 0.5
  @State private var lessonIsActive: Bool = true
  
  // New lesson mode
  @State private var isCreatingNew: Bool = false
  
  // Include inactive toggle
  @State private var showInactive: Bool = false
  
  var body: some View {
    NavigationStack {
      HSplitView {
        // Lesson list
        VStack(alignment: .leading, spacing: 0) {
          // Header
          HStack {
            Text("Lessons")
              .font(.headline)
            
            Spacer()
            
            Toggle("Inactive", isOn: $showInactive)
              .toggleStyle(.checkbox)
              .controlSize(.small)
          }
          .padding(8)
          
          Divider()
          
          if isLoading {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else if lessons.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "lightbulb.slash")
                .font(.title)
                .foregroundStyle(.secondary)
              Text("No lessons yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          } else {
            List(selection: $selectedLessonId) {
              ForEach(filteredLessons) { lesson in
                lessonRow(lesson)
                  .tag(lesson.id)
              }
            }
            .listStyle(.sidebar)
          }
          
          Divider()
          
          HStack {
            Button {
              createNewLesson()
            } label: {
              Label("New Lesson", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            
            Spacer()
          }
          .padding(8)
        }
        .frame(minWidth: 250, maxWidth: 350)
        
        // Editor
        editorView
      }
      .navigationTitle("Lessons for \(repo.name)")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .frame(minWidth: 800, minHeight: 500)
    .task {
      await loadLessons()
    }
    .onChange(of: showInactive) {
      Task { await loadLessons() }
    }
    .onChange(of: selectedLessonId) { _, newId in
      if let newId, let lesson = lessons.first(where: { $0.id == newId }) {
        loadLesson(lesson)
        isCreatingNew = false
      }
    }
  }
  
  private var filteredLessons: [LocalRAGLesson] {
    if showInactive {
      return lessons
    }
    return lessons.filter { $0.isActive }
  }
  
  // MARK: - Lesson Row
  
  @ViewBuilder
  private func lessonRow(_ lesson: LocalRAGLesson) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .top) {
        // Confidence indicator
        confidenceIndicator(lesson.confidence)
          .padding(.top, 4)
        
        Text(lesson.fixDescription)
          .font(.callout)
          .lineLimit(2)
        
        Spacer()
        
        if !lesson.isActive {
          Text("Inactive")
            .font(.caption2)
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .background(.orange.opacity(0.15), in: Capsule())
        }
      }
      
      HStack(spacing: 8) {
        if let pattern = lesson.filePattern, !pattern.isEmpty {
          Label(pattern, systemImage: "doc")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        
        Label("\(lesson.occurrences)×", systemImage: "arrow.clockwise")
          .font(.caption)
          .foregroundStyle(.secondary)
        
        Text(lesson.source)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 4)
          .background(.quaternary, in: Capsule())
      }
    }
    .padding(.vertical, 2)
  }
  
  @ViewBuilder
  private func confidenceIndicator(_ confidence: Float) -> some View {
    let color: Color = confidence >= 0.7 ? .green : confidence >= 0.4 ? .orange : .red
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .help("Confidence: \(Int(confidence * 100))%")
  }
  
  // MARK: - Editor View
  
  @ViewBuilder
  private var editorView: some View {
    if selectedLessonId != nil || isCreatingNew {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          // File Pattern
          VStack(alignment: .leading, spacing: 4) {
          Text("File Pattern")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("e.g., *.swift, app/models/*.rb", text: $lessonFilePattern)
            .textFieldStyle(.roundedBorder)
        }
        
        // Error Signature
        VStack(alignment: .leading, spacing: 4) {
          Text("Error Signature")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("e.g., cannot find 'X' in scope", text: $lessonErrorSignature)
            .textFieldStyle(.roundedBorder)
        }
        
        // Fix Description
        VStack(alignment: .leading, spacing: 4) {
          Text("Fix Description")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextField("Human-readable description of the fix", text: $lessonFixDescription)
            .textFieldStyle(.roundedBorder)
        }
        
        // Fix Code
        VStack(alignment: .leading, spacing: 4) {
          Text("Fix Code (optional)")
            .font(.caption)
            .foregroundStyle(.secondary)
          
          TextEditor(text: $lessonFixCode)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 100)
            .overlay(
              RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
            )
        }
        
        // Confidence & Active
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Confidence: \(Int(lessonConfidence * 100))%")
              .font(.caption)
              .foregroundStyle(.secondary)
            Slider(value: $lessonConfidence, in: 0.1...1.0, step: 0.05)
              .frame(width: 200)
          }
          
          Toggle("Active", isOn: $lessonIsActive)
        }
        
        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
        
        Spacer()
        
        // Action buttons
        HStack {
          if !isCreatingNew, selectedLessonId != nil {
            Button(role: .destructive) {
              Task { await deleteLesson() }
            } label: {
              Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
          }
          
          Spacer()
          
          if isCreatingNew {
            Button("Cancel") {
              isCreatingNew = false
              selectedLessonId = nil
              clearEditor()
            }
            .buttonStyle(.bordered)
          }
          
          Button(isCreatingNew ? "Create" : "Save") {
            Task {
              if isCreatingNew {
                await createLesson()
              } else {
                await saveLesson()
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(lessonFixDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        }
        .padding()
      }
      .frame(minWidth: 400)
    } else {
      VStack(spacing: 12) {
        Image(systemName: "doc.text.magnifyingglass")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)
        
        Text("Select a lesson to edit")
          .font(.callout)
          .foregroundStyle(.secondary)
        
        Text("or")
          .font(.caption)
          .foregroundStyle(.tertiary)
        
        Button {
          createNewLesson()
        } label: {
          Label("Create New Lesson", systemImage: "plus")
        }
        .buttonStyle(.bordered)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  
  // MARK: - Data Operations
  
  private func loadLessons() async {
    isLoading = true
    errorMessage = nil
    
    do {
      lessons = try await mcpServer.listLessons(
        repoPath: repo.rootPath,
        includeInactive: showInactive,
        limit: nil
      )
    } catch {
      errorMessage = error.localizedDescription
    }
    
    isLoading = false
  }
  
  private func loadLesson(_ lesson: LocalRAGLesson) {
    lessonFilePattern = lesson.filePattern ?? ""
    lessonErrorSignature = lesson.errorSignature ?? ""
    lessonFixDescription = lesson.fixDescription
    lessonFixCode = lesson.fixCode ?? ""
    lessonConfidence = lesson.confidence
    lessonIsActive = lesson.isActive
    errorMessage = nil
  }
  
  private func clearEditor() {
    lessonFilePattern = ""
    lessonErrorSignature = ""
    lessonFixDescription = ""
    lessonFixCode = ""
    lessonConfidence = 0.5
    lessonIsActive = true
    errorMessage = nil
  }
  
  private func createNewLesson() {
    selectedLessonId = nil
    isCreatingNew = true
    clearEditor()
  }
  
  private func createLesson() async {
    errorMessage = nil
    
    do {
      let lesson = try await mcpServer.addLesson(
        repoPath: repo.rootPath,
        filePattern: lessonFilePattern.isEmpty ? nil : lessonFilePattern,
        errorSignature: lessonErrorSignature.isEmpty ? nil : lessonErrorSignature,
        fixDescription: lessonFixDescription,
        fixCode: lessonFixCode.isEmpty ? nil : lessonFixCode,
        source: "manual"
      )
      
      isCreatingNew = false
      await loadLessons()
      selectedLessonId = lesson.id
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func saveLesson() async {
    guard let lessonId = selectedLessonId else { return }
    errorMessage = nil
    
    do {
      _ = try await mcpServer.updateLesson(
        id: lessonId,
        fixDescription: lessonFixDescription,
        fixCode: lessonFixCode.isEmpty ? nil : lessonFixCode,
        confidence: lessonConfidence,
        isActive: lessonIsActive
      )
      
      await loadLessons()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
  
  private func deleteLesson() async {
    guard let lessonId = selectedLessonId else { return }
    errorMessage = nil
    
    do {
      _ = try await mcpServer.deleteLesson(id: lessonId)
      selectedLessonId = nil
      clearEditor()
      await loadLessons()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Preview

#Preview {
  RAGLessonsView(
    repo: MCPServerService.RAGRepoInfo(
      id: "test",
      name: "project",
      rootPath: "/Users/test/code/project",
      lastIndexedAt: Date(),
      fileCount: 100,
      chunkCount: 500
    ),
    mcpServer: MCPServerService()
  )
}
