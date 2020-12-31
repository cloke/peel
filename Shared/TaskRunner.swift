//
//  TaskRunner.swift
//  KitchenSink (iOS)
//
//  Created by Cory Loken on 12/19/20.
//

import Foundation

enum TaskStatus {
  // Not super thrilled with complete having two arguments. Is there a better way?
  // data is needed for JSON deserialization. [String] is used for things like porcelain
  case complete(Data, [String])
  case buffer(String)
}

enum TaskError: Error {
  case unknownRunError(Error)
}

protocol TaskRunnerProtocol {
  func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())?) throws
}

extension TaskRunnerProtocol {
  // Help from Ray Wenderlich Forum
  // Method issues a callback on each line of data from process.
  // It will also return the entire output at the end of the process.
  // This is useful when we want the entire output to parse (JSON) versus line by line output for basic commands  
  func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())? = nil) throws {
    let process = Process()
    let pipe = Pipe()
    
    process.executableURL = URL(fileURLWithPath: url.rawValue)
    process.arguments = command
    
    process.standardOutput = pipe
    process.standardError = pipe
    let debuglog = DebugLog(label: "\(url.rawValue) \(command.joined(separator: " "))")
    DebugViewModel.shared.debugLogs.append(debuglog)
    /// Starts the external process.
    // (This does the same as ”launch()“, but it is a more modern API.)
    DispatchQueue.global(qos: .background).async {
      try? process.run()
      /// A buffer to store partial lines of data before we can turn them into strings.
      ///
      /// This is important, because we might get only the first or the second half of a multi‐byte character. Converting it before getting the rest of the character would result in corrupt replacements (�).
      var stream = Data()
      
      /// The POSIX newline character. (Windows line endings are more complicated, but they still contain it.)
      let newline = "\n"
      /// The newline as a single byte of data instead of a string (since we will be looking for it in data, not strings.
      let newlineData = newline.data(using: String.Encoding.utf8)!
      
      /// Reads whatever data the pipe has ready for us so far, returning `nil` when the pipe finished.
      func read() -> Data? {
        /// The data in the pipe.
        ///
        /// This will only be empty if the pipe is finished. Otherwise the pipe will stall until it has more. (See the documentation for `availableData`.)
        let newData = pipe.fileHandleForReading.availableData
        // If the new data is empty, the pipe was indicating that it is finished. `nil` is a better indicator of that, so we return `nil`.
        // If there actually is data, we return it.
        return newData.isEmpty ? nil : newData
      }
      
      // The purpose in the following loop‐based design is two‐fold:
      // 1. Each line of output can be handled in real time as it arrives.
      // 2. The entire thing is encapsulated in a single synchronous function. (It is much easier to send a synchronous task to another queue than it is to stall a queue to wait for the result of an asynchronous task.)
      
      /// A variable to store the output as we catch it.
      var outputData = Data()
      var outputArray = [String]()
      
      // Loop as long as “shouldEnd” is “false”.
      while process.isRunning {
        // “autoreleasepool” cleans up after some Objective C stuff Foundation will be doing.
        autoreleasepool {
          guard let newData = read() else {
            // “read()” returned `nil`, so we reached the end.
            //          shouldEnd = true
            // This returns from the autorelease pool.
            return
          }
          // Put the new data into the buffer.
          stream.append(newData)
          
          // Loop as long as we can find a line break in what’s left.
          while let lineEnd = stream.range(of: newlineData) {
            /// The data up to the newline.
            let lineData = stream.subdata(in: stream.startIndex ..< lineEnd.lowerBound)

            // Clear the part of the buffer we’ve already dealt with.
            stream.removeSubrange(..<lineEnd.upperBound)
            /// The line converted back to a string.
            let line = String(decoding: lineData, as: UTF8.self)

            outputData.append(lineData)
            outputArray.append(line)
            DispatchQueue.main.async {
              debuglog.entries.append(DebugLogEntry(entry: line))
              callback?(.buffer(line))
            }
          }
        }
      }
      DispatchQueue.main.async {
        callback?(.complete(outputData, outputArray))
      }
    }
    /// Stall until the external process is done, even if it closed its pipes early.
    //    while process.isRunning {}
    //
    //    /// Check whether it ended with success or an error.
    //    if process.terminationStatus == 0 {
    //      // It succeeded.
    //      // Return the output.
    //      return output
    //    } else {
    //      // It failed.
    ////      throw ExternalProcessError.processErrored(
    ////        exitCode: Int(process.terminationStatus),
    ////        output: output)
    //      return output
    //    }
    //    }
  }
}
