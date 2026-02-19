//
//  RAGToolsHandler+Lessons.swift
//  Peel
//
//  Handles: rag.lessons.list, .add, .query, .update, .delete, .applied
//  Split from RAGToolsHandler.swift as part of #301.
//

import Foundation
import MCPCore

extension RAGToolsHandler {
  // MARK: - rag.lessons.list (#210)
  
  func handleLessonsList(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let includeInactive = optionalBool("includeInactive", from: arguments, default: false)
    let limit = optionalInt("limit", from: arguments)
    
    do {
      let lessons = try await delegate.listLessons(repoPath: repoPath, includeInactive: includeInactive, limit: limit)
      let formatter = ISO8601DateFormatter()
      let payload = lessons.map { encodeLesson($0, formatter: formatter) }
      return (200, makeResult(id: id, result: ["lessons": payload]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.add (#210)
  
  func handleLessonsAdd(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    guard case .success(let fixDescription) = requireString("fixDescription", from: arguments, id: id) else {
      return missingParamError(id: id, param: "fixDescription")
    }
    
    let filePattern = optionalString("filePattern", from: arguments)
    let errorSignature = optionalString("errorSignature", from: arguments)
    let fixCode = optionalString("fixCode", from: arguments)
    let source = optionalString("source", from: arguments, default: "manual") ?? "manual"
    
    do {
      let lesson = try await delegate.addLesson(
        repoPath: repoPath,
        filePattern: filePattern,
        errorSignature: errorSignature,
        fixDescription: fixDescription,
        fixCode: fixCode,
        source: source
      )
      let formatter = ISO8601DateFormatter()
      return (200, makeResult(id: id, result: ["lesson": encodeLesson(lesson, formatter: formatter)]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.query (#210)
  
  func handleLessonsQuery(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let repoPath) = requireString("repoPath", from: arguments, id: id) else {
      return missingParamError(id: id, param: "repoPath")
    }
    
    let filePattern = optionalString("filePattern", from: arguments)
    let errorSignature = optionalString("errorSignature", from: arguments)
    let limit = optionalInt("limit", from: arguments, default: 20) ?? 20
    
    do {
      let lessons = try await delegate.queryLessons(
        repoPath: repoPath,
        filePattern: filePattern,
        errorSignature: errorSignature,
        limit: limit
      )
      let formatter = ISO8601DateFormatter()
      let payload = lessons.map { encodeLesson($0, formatter: formatter) }
      return (200, makeResult(id: id, result: ["lessons": payload, "query": ["filePattern": filePattern as Any, "errorSignature": errorSignature as Any]]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.update (#210)
  
  func handleLessonsUpdate(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    let fixDescription = optionalString("fixDescription", from: arguments)
    let fixCode = optionalString("fixCode", from: arguments)
    // JSON numbers come in as Double
    let confidence: Double? = arguments["confidence"] as? Double
    let isActive = arguments["isActive"] as? Bool
    
    do {
      guard let lesson = try await delegate.updateLesson(
        id: lessonId,
        fixDescription: fixDescription,
        fixCode: fixCode,
        confidence: confidence,
        isActive: isActive
      ) else {
        return notFoundError(id: id, what: "Lesson")
      }
      let formatter = ISO8601DateFormatter()
      return (200, makeResult(id: id, result: ["lesson": encodeLesson(lesson, formatter: formatter)]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.delete (#210)
  
  func handleLessonsDelete(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    do {
      let deleted = try await delegate.deleteLesson(id: lessonId)
      if !deleted {
        return notFoundError(id: id, what: "Lesson")
      }
      return (200, makeResult(id: id, result: ["deleted": lessonId]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  // MARK: - rag.lessons.applied (#210 Phase 4)
  
  func handleLessonsApplied(id: Any?, arguments: [String: Any], delegate: RAGToolsHandlerDelegate) async -> (Int, Data) {
    guard case .success(let lessonId) = requireString("lessonId", from: arguments, id: id) else {
      return missingParamError(id: id, param: "lessonId")
    }
    
    // Optional: whether the lesson actually helped (for future negative feedback)
    let success = optionalBool("success", from: arguments, default: true)
    
    do {
      try await delegate.recordLessonApplied(id: lessonId, success: success)
      return (200, makeResult(id: id, result: ["applied": lessonId, "success": success]))
    } catch {
      return (500, makeError(id: id, code: JSONRPCResponseBuilder.ErrorCode.internalError, message: error.localizedDescription))
    }
  }
  
  /// Encode a lesson to a dictionary for JSON response
  private func encodeLesson(_ lesson: LocalRAGLesson, formatter: ISO8601DateFormatter) -> [String: Any] {
    var result: [String: Any] = [
      "id": lesson.id,
      "repoId": lesson.repoId,
      "fixDescription": lesson.fixDescription,
      "confidence": lesson.confidence,
      "applyCount": lesson.applyCount,
      "successCount": lesson.successCount,
      "source": lesson.source,
      "isActive": lesson.isActive,
      "createdAt": lesson.createdAt
    ]
    if let filePattern = lesson.filePattern {
      result["filePattern"] = filePattern
    }
    if let errorSignature = lesson.errorSignature {
      result["errorSignature"] = errorSignature
    }
    if let fixCode = lesson.fixCode {
      result["fixCode"] = fixCode
    }
    if let updatedAt = lesson.updatedAt {
      result["updatedAt"] = updatedAt
    }
    return result
  }
  
}
