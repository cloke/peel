import Foundation

/// Streaming line reader for reading files or stdin line-by-line.
public final class LineReader: Sequence, IteratorProtocol, @unchecked Sendable {
  private let handle: FileHandle
  private var buffer = Data()
  private var isEOF = false
  private let chunkSize = 64 * 1024

  public init(path: String?) throws {
    if let path {
      handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    } else {
      handle = FileHandle.standardInput
    }
  }

  public func next() -> String? {
    while true {
      if let range = buffer.firstRange(of: Data([0x0A])) {
        let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return decodeLine(lineData, appendNewline: true)
      }

      if isEOF {
        guard !buffer.isEmpty else { return nil }
        let lineData = buffer
        buffer.removeAll()
        return decodeLine(lineData, appendNewline: false)
      }

      do {
        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty {
          isEOF = true
        } else {
          buffer.append(chunk)
        }
      } catch {
        isEOF = true
      }
    }
  }

  private func decodeLine(_ data: Data, appendNewline: Bool) -> String? {
    if var line = String(data: data, encoding: .utf8) {
      if appendNewline { line.append("\n") }
      return line
    }
    if var line = String(data: data, encoding: .isoLatin1) {
      if appendNewline { line.append("\n") }
      return line
    }
    return nil
  }
}
