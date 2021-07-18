//
//  File.swift
//  File
//
//  Created by Cory Loken on 7/18/21.
//

import Foundation

struct Fixtures {
  static let commit = #"""
  {
  "sha": "7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
  "node_id": "MDY6Q29tbWl0MzI1ODE0MjUxOjdkM2NjMWU2NDUwYTZlMGY2N2U3ZTgzZTMyYzNlMzA5NDJkNDkzMjE=",
  "commit": {
    "author": {
      "name": "cloke",
      "email": "cory@me.com",
      "date": "2021-02-01T19:14:36Z"
    },
    "committer": {
      "name": "cloke",
      "email": "cory@me.com",
      "date": "2021-02-01T19:14:36Z"
    },
    "message": "Split task runner reposnse to stdOut and err. Will need to handle err.",
    "tree": {
      "sha": "8e0c5a9395896c6784df9a48e5d9df7de56b1252",
      "url": "https://api.github.com/repos/crunchybananas/kitchen-sink/git/trees/8e0c5a9395896c6784df9a48e5d9df7de56b1252"
    },
    "url": "https://api.github.com/repos/crunchybananas/kitchen-sink/git/commits/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
    "comment_count": 0,
    "verification": {
      "verified": false,
      "reason": "unsigned",
      "signature": null,
      "payload": null
    }
  },
  "url": "https://api.github.com/repos/crunchybananas/kitchen-sink/commits/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
  "html_url": "https://github.com/crunchybananas/kitchen-sink/commit/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
  "comments_url": "https://api.github.com/repos/crunchybananas/kitchen-sink/commits/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321/comments",
  "author": {
    "login": "cloke",
    "id": 15304,
    "node_id": "MDQ6VXNlcjE1MzA0",
    "avatar_url": "https://avatars.githubusercontent.com/u/15304?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/cloke",
    "html_url": "https://github.com/cloke",
    "followers_url": "https://api.github.com/users/cloke/followers",
    "following_url": "https://api.github.com/users/cloke/following{/other_user}",
    "gists_url": "https://api.github.com/users/cloke/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/cloke/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/cloke/subscriptions",
    "organizations_url": "https://api.github.com/users/cloke/orgs",
    "repos_url": "https://api.github.com/users/cloke/repos",
    "events_url": "https://api.github.com/users/cloke/events{/privacy}",
    "received_events_url": "https://api.github.com/users/cloke/received_events",
    "type": "User",
    "site_admin": false
  },
  "committer": {
    "login": "cloke",
    "id": 15304,
    "node_id": "MDQ6VXNlcjE1MzA0",
    "avatar_url": "https://avatars.githubusercontent.com/u/15304?v=4",
    "gravatar_id": "",
    "url": "https://api.github.com/users/cloke",
    "html_url": "https://github.com/cloke",
    "followers_url": "https://api.github.com/users/cloke/followers",
    "following_url": "https://api.github.com/users/cloke/following{/other_user}",
    "gists_url": "https://api.github.com/users/cloke/gists{/gist_id}",
    "starred_url": "https://api.github.com/users/cloke/starred{/owner}{/repo}",
    "subscriptions_url": "https://api.github.com/users/cloke/subscriptions",
    "organizations_url": "https://api.github.com/users/cloke/orgs",
    "repos_url": "https://api.github.com/users/cloke/repos",
    "events_url": "https://api.github.com/users/cloke/events{/privacy}",
    "received_events_url": "https://api.github.com/users/cloke/received_events",
    "type": "User",
    "site_admin": false
  },
  "parents": [
    {
      "sha": "48dfc68157fa3b8855a74ff1843be7ff80efb575",
      "url": "https://api.github.com/repos/crunchybananas/kitchen-sink/commits/48dfc68157fa3b8855a74ff1843be7ff80efb575",
      "html_url": "https://github.com/crunchybananas/kitchen-sink/commit/48dfc68157fa3b8855a74ff1843be7ff80efb575"
    }
  ],
  "stats": {
    "total": 17,
    "additions": 10,
    "deletions": 7
  },
  "files": [
    {
      "sha": "77423aca50c6fa255de069295e498639a3caec8a",
      "filename": "Local Packages/TaskRunner/Sources/TaskRunner/TaskRunner.swift",
      "status": "modified",
      "additions": 6,
      "deletions": 5,
      "changes": 11,
      "blob_url": "https://github.com/crunchybananas/kitchen-sink/blob/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321/Local%20Packages/TaskRunner/Sources/TaskRunner/TaskRunner.swift",
      "raw_url": "https://github.com/crunchybananas/kitchen-sink/raw/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321/Local%20Packages/TaskRunner/Sources/TaskRunner/TaskRunner.swift",
      "contents_url": "https://api.github.com/repos/crunchybananas/kitchen-sink/contents/Local%20Packages/TaskRunner/Sources/TaskRunner/TaskRunner.swift?ref=7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
      "patch": "@@ -60,13 +60,14 @@ public extension TaskRunnerProtocol {\n   // This is useful when we want the entire output to parse (JSON) versus line by line output for basic commands\n   func run(_ url: Executable, command: [String], callback: ((TaskStatus) -> ())? = nil) throws {\n     let process = Process()\n-    let pipe = Pipe()\n-    \n+    let pipeOutput = Pipe()\n+    let pipeError = Pipe()\n+\n     process.executableURL = URL(fileURLWithPath: url.rawValue)\n     process.arguments = command\n     \n-    process.standardOutput = pipe\n-    process.standardError = pipe\n+    process.standardOutput = pipeOutput\n+    process.standardError = pipeError\n     let debuglog = DebugLog(label: \"\\(url.rawValue) \\(command.joined(separator: \" \"))\")\n     DebugViewModel.shared.debugLogs.append(debuglog)\n     /// Starts the external process.\n@@ -88,7 +89,7 @@ public extension TaskRunnerProtocol {\n         /// The data in the pipe.\n         ///\n         /// This will only be empty if the pipe is finished. Otherwise the pipe will stall until it has more. (See the documentation for `availableData`.)\n-        let newData = pipe.fileHandleForReading.availableData\n+        let newData = pipeOutput.fileHandleForReading.availableData\n         // If the new data is empty, the pipe was indicating that it is finished. `nil` is a better indicator of that, so we return `nil`.\n         // If there actually is data, we return it.\n         return newData.isEmpty ? nil : newData"
    },
    {
      "sha": "4b7b3e2a14f959b8f5bdc8bdf98ca734f3f419a3",
      "filename": "README.md",
      "status": "modified",
      "additions": 4,
      "deletions": 2,
      "changes": 6,
      "blob_url": "https://github.com/crunchybananas/kitchen-sink/blob/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321/README.md",
      "raw_url": "https://github.com/crunchybananas/kitchen-sink/raw/7d3cc1e6450a6e0f67e7e83e32c3e30942d49321/README.md",
      "contents_url": "https://api.github.com/repos/crunchybananas/kitchen-sink/contents/README.md?ref=7d3cc1e6450a6e0f67e7e83e32c3e30942d49321",
      "patch": "@@ -1,9 +1,10 @@\n # TODO GENERAL\n - [X] Look at organizing tool specific code into local packages\n+- [ ] TaskRunner should handle stdError and report back to the user\n \n #  TODO GIT\n ### General\n-- [ ] Switch branch while file list is selected does not refresh list. Ideally the entire view hiarachy would be repainted and selection removed. \n+- [X] Switch branch while file list is selected does not refresh list. Ideally the entire view hiarachy would be repainted and selection removed. \n - [ ] Switch branch and branches should refresh. Again full repaint would be ideal\n - [ ] When a file is moved the commit view shows errors on removed files. Status \"AD\" and \"R\" are not taken into account.\n - [X] Convert file change list to an object that includes status changes and escaped path.\n@@ -17,11 +18,12 @@\n - [X] Require commit message before button is enabled\n - [X] Stage files\n - [X] Unstage files\n-- [ ] Unstaged files are still committed\n+- [X] Unstaged files are still committed\n - [ ] Amend\n - [X] The file list of commits shows quotes\n - [X] Revert file\n - [ ] Revert all files (requires multiselect support to be added)\n+- [ ] Add a way to check all files to be committed (ie changes should have the checkbox enabled)\n \n ### Pull\n - [ ] Pull remote into checked out branch"
    }
  ]
  }
  """#.data(using: .utf8)!
}
