//
//  Commit.swift
//  Commit
//
//  Created by Cory Loken on 7/16/21.
//

import Foundation

extension Github {
  public struct CommitUser: Codable {
    var name: String
    var email: String
    var date: String
    
    // TODO: This code should go into crunchy common as "relative date style". Could it be a modifier? Text("something").relativeDate()
    var dateFormated: String {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
      if let date = formatter.date(from: date) {
        formatter.doesRelativeDateFormatting = true
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
      }
      return ""
    }
  }
  
  public struct CommitSnapshot: Codable {
    public var author: CommitUser
    public var committer: CommitUser
    
    public var message: String
//      "tree": {
//        "sha": "f77d0873d3e95f7e19cd74715b9f7333b1fc04af",
//        "url": "https://api.github.com/repos/tuitionio/vue-tio-modal/git/trees/f77d0873d3e95f7e19cd74715b9f7333b1fc04af"
//      },
//      "url": "https://api.github.com/repos/tuitionio/vue-tio-modal/git/commits/118c129254390c203c3e778569a7880eeb212645",
//      "comment_count": 0,
//      "verification": {
//        "verified": true,
//        "reason": "valid",
//        "signature": "-----BEGIN PGP SIGNATURE-----\n\nwsBcBAABCAAQBQJbGwWOCRBK7hj4Ov3rIwAAdHIIAA9UkscE1YPkXb/vIdZ7xnww\nV01eYvbC1tifTZeS61HnKy345xCq7dHvCNfU+AyGcD+pcY7YcOR2fJTmT0hYkFyb\nFrxe4I71yBOhmSI3Pjzzr2pepvvR2zYfN+qPs7GuYajyijQWI2Ia/AtoagB583LT\nsTAh1aPddWUDK/9pVX/VKznVCCQ92n6vOfsr2Mhb+x5S5D8cuUvHMaHCVXnPEe7u\nMrXaLFvdYohucq4LzwfsmYkcq2UA2ZfIWaCT3Q+m4GgMaiiHM2I4P/7oRaHyqAba\nvuvraa9mKJQxdm2IrdDlFjZmEKQD/7ASHXwzCmWO125d7+FFZLmaSU2ejezhd/o=\n=/UBD\n-----END PGP SIGNATURE-----\n",
//        "payload": "tree f77d0873d3e95f7e19cd74715b9f7333b1fc04af\nauthor Artur Grigio <fsastudent@yahoo.com> 1528497550 -0700\ncommitter GitHub <noreply@github.com> 1528497550 -0700\n\nInitial commit"
//      }

  }
  public struct Commit: Codable {
    public var sha: String
    public var node_id: String
    public var commit: CommitSnapshot
    public var url: String
    public var html_url: String
    public var comments_url: String
    public var author: User?
    public var committer: User?
//    "parents": []
    
  }
}
