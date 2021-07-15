//
//  PullRequest.swift
//  PullRequest
//
//  Created by Cory Loken on 7/14/21.
//

extension Github {
  public struct PullRequest: Codable, Identifiable {
    public var url: String
    public var id: Int
    public var node_id: String
    public var html_url: String
    public var diff_url: String
    public var patch_url: String
    public var issue_url: String
    public var number: Int
    public var state: String
    public var locked: Bool
    public var title: String
    public var user: User
    public var body: String
    public var created_at: String
    public var updated_at: String
    public var closed_at: String?
    public var merged_at: String?
    public var merge_commit_sha: String
    public var assignee: User?
    public var assignees: [User]
    public var requested_reviewers: [User]
    //      "requested_teams": [],
    //      var labels: [String]
    //      "milestone": null,
    public var draft: Bool
    public var commits_url: String
    public var review_comments_url: String
    public var review_comment_url: String
    public var comments_url: String
    public var statuses_url: String
    //      "head": {
    //        "label": "logerrors:master",
    //        "ref": "master",
    //        "sha": "9f81418f73fbebff5974c33bd705eaa8957f1dfc",
    //        "user": {
    //          "login": "logerrors",
    //          "id": 31824303,
    //          "node_id": "MDQ6VXNlcjMxODI0MzAz",
    //          "avatar_url": "https://avatars.githubusercontent.com/u/31824303?v=4",
    //          "gravatar_id": "",
    //          "url": "https://api.github.com/users/logerrors",
    //          "html_url": "https://github.com/logerrors",
    //          "followers_url": "https://api.github.com/users/logerrors/followers",
    //          "following_url": "https://api.github.com/users/logerrors/following{/other_user}",
    //          "gists_url": "https://api.github.com/users/logerrors/gists{/gist_id}",
    //          "starred_url": "https://api.github.com/users/logerrors/starred{/owner}{/repo}",
    //          "subscriptions_url": "https://api.github.com/users/logerrors/subscriptions",
    //          "organizations_url": "https://api.github.com/users/logerrors/orgs",
    //          "repos_url": "https://api.github.com/users/logerrors/repos",
    //          "events_url": "https://api.github.com/users/logerrors/events{/privacy}",
    //          "received_events_url": "https://api.github.com/users/logerrors/received_events",
    //          "type": "User",
    //          "site_admin": false
    //        },
    //        "repo": {
    //          "id": 383948788,
    //          "node_id": "MDEwOlJlcG9zaXRvcnkzODM5NDg3ODg=",
    //          "name": "Hello-World",
    //          "full_name": "logerrors/Hello-World",
    //          "private": false,
    //          "owner": {
    //            "login": "logerrors",
    //            "id": 31824303,
    //            "node_id": "MDQ6VXNlcjMxODI0MzAz",
    //            "avatar_url": "https://avatars.githubusercontent.com/u/31824303?v=4",
    //            "gravatar_id": "",
    //            "url": "https://api.github.com/users/logerrors",
    //            "html_url": "https://github.com/logerrors",
    //            "followers_url": "https://api.github.com/users/logerrors/followers",
    //            "following_url": "https://api.github.com/users/logerrors/following{/other_user}",
    //            "gists_url": "https://api.github.com/users/logerrors/gists{/gist_id}",
    //            "starred_url": "https://api.github.com/users/logerrors/starred{/owner}{/repo}",
    //            "subscriptions_url": "https://api.github.com/users/logerrors/subscriptions",
    //            "organizations_url": "https://api.github.com/users/logerrors/orgs",
    //            "repos_url": "https://api.github.com/users/logerrors/repos",
    //            "events_url": "https://api.github.com/users/logerrors/events{/privacy}",
    //            "received_events_url": "https://api.github.com/users/logerrors/received_events",
    //            "type": "User",
    //            "site_admin": false
    //          },
    //          "html_url": "https://github.com/logerrors/Hello-World",
    //          "description": "My first repository on GitHub!",
    //          "fork": true,
    //          "url": "https://api.github.com/repos/logerrors/Hello-World",
    //          "forks_url": "https://api.github.com/repos/logerrors/Hello-World/forks",
    //          "keys_url": "https://api.github.com/repos/logerrors/Hello-World/keys{/key_id}",
    //          "collaborators_url": "https://api.github.com/repos/logerrors/Hello-World/collaborators{/collaborator}",
    //          "teams_url": "https://api.github.com/repos/logerrors/Hello-World/teams",
    //          "hooks_url": "https://api.github.com/repos/logerrors/Hello-World/hooks",
    //          "issue_events_url": "https://api.github.com/repos/logerrors/Hello-World/issues/events{/number}",
    //          "events_url": "https://api.github.com/repos/logerrors/Hello-World/events",
    //          "assignees_url": "https://api.github.com/repos/logerrors/Hello-World/assignees{/user}",
    //          "branches_url": "https://api.github.com/repos/logerrors/Hello-World/branches{/branch}",
    //          "tags_url": "https://api.github.com/repos/logerrors/Hello-World/tags",
    //          "blobs_url": "https://api.github.com/repos/logerrors/Hello-World/git/blobs{/sha}",
    //          "git_tags_url": "https://api.github.com/repos/logerrors/Hello-World/git/tags{/sha}",
    //          "git_refs_url": "https://api.github.com/repos/logerrors/Hello-World/git/refs{/sha}",
    //          "trees_url": "https://api.github.com/repos/logerrors/Hello-World/git/trees{/sha}",
    //          "statuses_url": "https://api.github.com/repos/logerrors/Hello-World/statuses/{sha}",
    //          "languages_url": "https://api.github.com/repos/logerrors/Hello-World/languages",
    //          "stargazers_url": "https://api.github.com/repos/logerrors/Hello-World/stargazers",
    //          "contributors_url": "https://api.github.com/repos/logerrors/Hello-World/contributors",
    //          "subscribers_url": "https://api.github.com/repos/logerrors/Hello-World/subscribers",
    //          "subscription_url": "https://api.github.com/repos/logerrors/Hello-World/subscription",
    //          "commits_url": "https://api.github.com/repos/logerrors/Hello-World/commits{/sha}",
    //          "git_commits_url": "https://api.github.com/repos/logerrors/Hello-World/git/commits{/sha}",
    //          "comments_url": "https://api.github.com/repos/logerrors/Hello-World/comments{/number}",
    //          "issue_comment_url": "https://api.github.com/repos/logerrors/Hello-World/issues/comments{/number}",
    //          "contents_url": "https://api.github.com/repos/logerrors/Hello-World/contents/{+path}",
    //          "compare_url": "https://api.github.com/repos/logerrors/Hello-World/compare/{base}...{head}",
    //          "merges_url": "https://api.github.com/repos/logerrors/Hello-World/merges",
    //          "archive_url": "https://api.github.com/repos/logerrors/Hello-World/{archive_format}{/ref}",
    //          "downloads_url": "https://api.github.com/repos/logerrors/Hello-World/downloads",
    //          "issues_url": "https://api.github.com/repos/logerrors/Hello-World/issues{/number}",
    //          "pulls_url": "https://api.github.com/repos/logerrors/Hello-World/pulls{/number}",
    //          "milestones_url": "https://api.github.com/repos/logerrors/Hello-World/milestones{/number}",
    //          "notifications_url": "https://api.github.com/repos/logerrors/Hello-World/notifications{?since,all,participating}",
    //          "labels_url": "https://api.github.com/repos/logerrors/Hello-World/labels{/name}",
    //          "releases_url": "https://api.github.com/repos/logerrors/Hello-World/releases{/id}",
    //          "deployments_url": "https://api.github.com/repos/logerrors/Hello-World/deployments",
    //          "created_at": "2021-07-07T23:32:53Z",
    //          "updated_at": "2021-07-07T23:41:01Z",
    //          "pushed_at": "2021-07-08T01:18:14Z",
    //          "git_url": "git://github.com/logerrors/Hello-World.git",
    //          "ssh_url": "git@github.com:logerrors/Hello-World.git",
    //          "clone_url": "https://github.com/logerrors/Hello-World.git",
    //          "svn_url": "https://github.com/logerrors/Hello-World",
    //          "homepage": "",
    //          "size": 1,
    //          "stargazers_count": 0,
    //          "watchers_count": 0,
    //          "language": null,
    //          "has_issues": false,
    //          "has_projects": true,
    //          "has_downloads": true,
    //          "has_wiki": true,
    //          "has_pages": false,
    //          "forks_count": 0,
    //          "mirror_url": null,
    //          "archived": false,
    //          "disabled": false,
    //          "open_issues_count": 0,
    //          "license": null,
    //          "forks": 0,
    //          "open_issues": 0,
    //          "watchers": 0,
    //          "default_branch": "master"
    //        }
    //      },
    //      "base": {
    //        "label": "octocat:master",
    //        "ref": "master",
    //        "sha": "7fd1a60b01f91b314f59955a4e4d4e80d8edf11d",
    //        "user": {
    //          "login": "octocat",
    //          "id": 583231,
    //          "node_id": "MDQ6VXNlcjU4MzIzMQ==",
    //          "avatar_url": "https://avatars.githubusercontent.com/u/583231?v=4",
    //          "gravatar_id": "",
    //          "url": "https://api.github.com/users/octocat",
    //          "html_url": "https://github.com/octocat",
    //          "followers_url": "https://api.github.com/users/octocat/followers",
    //          "following_url": "https://api.github.com/users/octocat/following{/other_user}",
    //          "gists_url": "https://api.github.com/users/octocat/gists{/gist_id}",
    //          "starred_url": "https://api.github.com/users/octocat/starred{/owner}{/repo}",
    //          "subscriptions_url": "https://api.github.com/users/octocat/subscriptions",
    //          "organizations_url": "https://api.github.com/users/octocat/orgs",
    //          "repos_url": "https://api.github.com/users/octocat/repos",
    //          "events_url": "https://api.github.com/users/octocat/events{/privacy}",
    //          "received_events_url": "https://api.github.com/users/octocat/received_events",
    //          "type": "User",
    //          "site_admin": false
    //        },
    //        "repo": {
    //          "id": 1296269,
    //          "node_id": "MDEwOlJlcG9zaXRvcnkxMjk2MjY5",
    //          "name": "Hello-World",
    //          "full_name": "octocat/Hello-World",
    //          "private": false,
    //          "owner": {
    //            "login": "octocat",
    //            "id": 583231,
    //            "node_id": "MDQ6VXNlcjU4MzIzMQ==",
    //            "avatar_url": "https://avatars.githubusercontent.com/u/583231?v=4",
    //            "gravatar_id": "",
    //            "url": "https://api.github.com/users/octocat",
    //            "html_url": "https://github.com/octocat",
    //            "followers_url": "https://api.github.com/users/octocat/followers",
    //            "following_url": "https://api.github.com/users/octocat/following{/other_user}",
    //            "gists_url": "https://api.github.com/users/octocat/gists{/gist_id}",
    //            "starred_url": "https://api.github.com/users/octocat/starred{/owner}{/repo}",
    //            "subscriptions_url": "https://api.github.com/users/octocat/subscriptions",
    //            "organizations_url": "https://api.github.com/users/octocat/orgs",
    //            "repos_url": "https://api.github.com/users/octocat/repos",
    //            "events_url": "https://api.github.com/users/octocat/events{/privacy}",
    //            "received_events_url": "https://api.github.com/users/octocat/received_events",
    //            "type": "User",
    //            "site_admin": false
    //          },
    //          "html_url": "https://github.com/octocat/Hello-World",
    //          "description": "My first repository on GitHub!",
    //          "fork": false,
    //          "url": "https://api.github.com/repos/octocat/Hello-World",
    //          "forks_url": "https://api.github.com/repos/octocat/Hello-World/forks",
    //          "keys_url": "https://api.github.com/repos/octocat/Hello-World/keys{/key_id}",
    //          "collaborators_url": "https://api.github.com/repos/octocat/Hello-World/collaborators{/collaborator}",
    //          "teams_url": "https://api.github.com/repos/octocat/Hello-World/teams",
    //          "hooks_url": "https://api.github.com/repos/octocat/Hello-World/hooks",
    //          "issue_events_url": "https://api.github.com/repos/octocat/Hello-World/issues/events{/number}",
    //          "events_url": "https://api.github.com/repos/octocat/Hello-World/events",
    //          "assignees_url": "https://api.github.com/repos/octocat/Hello-World/assignees{/user}",
    //          "branches_url": "https://api.github.com/repos/octocat/Hello-World/branches{/branch}",
    //          "tags_url": "https://api.github.com/repos/octocat/Hello-World/tags",
    //          "blobs_url": "https://api.github.com/repos/octocat/Hello-World/git/blobs{/sha}",
    //          "git_tags_url": "https://api.github.com/repos/octocat/Hello-World/git/tags{/sha}",
    //          "git_refs_url": "https://api.github.com/repos/octocat/Hello-World/git/refs{/sha}",
    //          "trees_url": "https://api.github.com/repos/octocat/Hello-World/git/trees{/sha}",
    //          "statuses_url": "https://api.github.com/repos/octocat/Hello-World/statuses/{sha}",
    //          "languages_url": "https://api.github.com/repos/octocat/Hello-World/languages",
    //          "stargazers_url": "https://api.github.com/repos/octocat/Hello-World/stargazers",
    //          "contributors_url": "https://api.github.com/repos/octocat/Hello-World/contributors",
    //          "subscribers_url": "https://api.github.com/repos/octocat/Hello-World/subscribers",
    //          "subscription_url": "https://api.github.com/repos/octocat/Hello-World/subscription",
    //          "commits_url": "https://api.github.com/repos/octocat/Hello-World/commits{/sha}",
    //          "git_commits_url": "https://api.github.com/repos/octocat/Hello-World/git/commits{/sha}",
    //          "comments_url": "https://api.github.com/repos/octocat/Hello-World/comments{/number}",
    //          "issue_comment_url": "https://api.github.com/repos/octocat/Hello-World/issues/comments{/number}",
    //          "contents_url": "https://api.github.com/repos/octocat/Hello-World/contents/{+path}",
    //          "compare_url": "https://api.github.com/repos/octocat/Hello-World/compare/{base}...{head}",
    //          "merges_url": "https://api.github.com/repos/octocat/Hello-World/merges",
    //          "archive_url": "https://api.github.com/repos/octocat/Hello-World/{archive_format}{/ref}",
    //          "downloads_url": "https://api.github.com/repos/octocat/Hello-World/downloads",
    //          "issues_url": "https://api.github.com/repos/octocat/Hello-World/issues{/number}",
    //          "pulls_url": "https://api.github.com/repos/octocat/Hello-World/pulls{/number}",
    //          "milestones_url": "https://api.github.com/repos/octocat/Hello-World/milestones{/number}",
    //          "notifications_url": "https://api.github.com/repos/octocat/Hello-World/notifications{?since,all,participating}",
    //          "labels_url": "https://api.github.com/repos/octocat/Hello-World/labels{/name}",
    //          "releases_url": "https://api.github.com/repos/octocat/Hello-World/releases{/id}",
    //          "deployments_url": "https://api.github.com/repos/octocat/Hello-World/deployments",
    //          "created_at": "2011-01-26T19:01:12Z",
    //          "updated_at": "2021-07-14T21:50:45Z",
    //          "pushed_at": "2021-07-07T23:48:42Z",
    //          "git_url": "git://github.com/octocat/Hello-World.git",
    //          "ssh_url": "git@github.com:octocat/Hello-World.git",
    //          "clone_url": "https://github.com/octocat/Hello-World.git",
    //          "svn_url": "https://github.com/octocat/Hello-World",
    //          "homepage": "",
    //          "size": 1,
    //          "stargazers_count": 1669,
    //          "watchers_count": 1669,
    //          "language": null,
    //          "has_issues": true,
    //          "has_projects": true,
    //          "has_downloads": true,
    //          "has_wiki": true,
    //          "has_pages": false,
    //          "forks_count": 1577,
    //          "mirror_url": null,
    //          "archived": false,
    //          "disabled": false,
    //          "open_issues_count": 535,
    //          "license": null,
    //          "forks": 1577,
    //          "open_issues": 535,
    //          "watchers": 1669,
    //          "default_branch": "master"
    //        }
    //      },
    //      "_links": {
    //        "self": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/pulls/997"
    //        },
    //        "html": {
    //          "href": "https://github.com/octocat/Hello-World/pull/997"
    //        },
    //        "issue": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/issues/997"
    //        },
    //        "comments": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/issues/997/comments"
    //        },
    //        "review_comments": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/pulls/997/comments"
    //        },
    //        "review_comment": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/pulls/comments{/number}"
    //        },
    //        "commits": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/pulls/997/commits"
    //        },
    //        "statuses": {
    //          "href": "https://api.github.com/repos/octocat/Hello-World/statuses/9f81418f73fbebff5974c33bd705eaa8957f1dfc"
    //        }
    //      },
    public var author_association: String
    public var auto_merge: String?
    public var active_lock_reason: String?
  }
}
