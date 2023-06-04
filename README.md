# TODO GENERAL
- [ ] Most of the git UI could be reused in the github package. Should probably make GitUI package.
- [X] Look at organizing tool specific code into local packages
- [ ] TaskRunner should handle stdError and report back to the user
- [ ] Hook github view into debugger window
- [ ] Figure out what would make sense for iOS / iPad
  - [ ] Most of the github view will work on mobile, but the git package needs to be reworked to not require MacOS and optionally provide views not tied to system calls.

#  TODO GITHUB
### General
- [ ] Notification badges. 
  - [ ] On the dock icon
  - [ ] Determine where inside the app?
- [ ] Use generated links from organization object. This would future proof changes in the git api assuming the property names don't change.
- [ ] Add the ability to add / remove organizations by removing token and reauthorizing.
- [ ] Create view that is responsible for loading review status. It should cancel on unload and have a delay in the request to minimize queries to git.
- [ ] Add a counter to the UI that shows request count. Ideally this would somehow show with a trailing 1 hour count so we can see how much we hit the github api. Need to stay under 5000 an hour. 
- [ ] Remove need to click the login button if a token exists.
- [ ] Add error checking.
  - [ ] Handle token expiration.
- [ ] Add navigation for PRs, Issues
- [ ] Figure out how to allow decodable to use the private key name that indicates a repo is private. If it requires opting all keys into a Coding Keys enum maybe we handle this at the repoonse layer?
- [ ] Display all of my repositories on personal account
- [ ] Show watching
- [ ] Show starred
- [ ] User / Organiztion is currently unified to user, but it would be useful to separate them again and figure out a base protocol. For example `login` can be null on user, but not org, so we have to do a lot of extra nuull checks for no reason. 
- [ ] Async image seems to have issues never leaving the .empty state when in a list view. May be a swift issue?

### Pull Requests
- [X] Pull request view
- [X] Display comments
- [ ] Reviewer status
- [X] Diff view (use common git code)
- [ ] Research approver flow. This will be a huge undertaking since it requires direct comments on diff lines.

### Issues
- [X] Issues view
- [ ] Ability to see issues
  - [ ] Ability to see issues across repos
  - [ ] Ability to see issues across orgs
- [ ] Create issues
  - [ ] Turn this document into issues and use app to manage them
  - [X] Create with title, body, and reporter
    - [ ] Add validations
    - [ ] See if delay in render is slow api or our response?
  - [ ] Add image support. There is no way to do this in the api, but we can host the files or use base64 encoded images. 
    
### Actions
- [X] Actions view
- [ ] Can we show some of the billing / usage information in this view? I'd like to know how many minutes I've used. 
- [ ] Browse artifacts
- [ ] Download artifacts
- [ ] Show running actions
- [ ] Show completed actions
- [ ] Show status of all actions across organization
- [ ] Show status of all actions across all organizations
  
#  TODO GIT
### General
- [ ] The view model struct should not be a singleton, but rather a top level object to the scene. This will allow each window to have its own repo. 
- [X] Switch branch while file list is selected does not refresh list. Ideally the entire view hiarachy would be repainted and selection removed. 
- [ ] Switch branch and branches should refresh. Again full repaint would be ideal
- [ ] When a file is moved the commit view shows errors on removed files. Status "AD" and "R" are not taken into account.
- [X] Convert file change list to an object that includes status changes and escaped path.
  - [ ] Convert staus to an enum that outlines mod types
- [ ] Training wheels mode. When a destructive action takes place show an "are you sure" modal, but then allow to not show again.
- [ ] Add a timed mechanism for checking for local and remote changes
- [ ] Set a check for minimum git version (>2.23 is required). 
- [ ] Bundle git into project
- [X] When deleting a branch log is flooded with error about publishing changes on background thread

### Clone
- [X] ssh
- [ ] https

### Commits
- [X] Require commit message before button is enabled
- [X] Stage files
- [X] Unstage files
- [X] Unstaged files are still committed
- [ ] Amend
- [X] The file list of commits shows quotes
- [X] Revert file
- [ ] Revert all files (requires multiselect support to be added)
- [X] Add a way to check all files to be committed (ie changes should have the checkbox enabled)
- [ ] Continue to look at what is considered staged or unstaged and fix check boxes as needed
- [ ] Ensure at least on file is staged before commit
- [ ] Stage all files
- [X] Preview icons

### Pull
- [ ] Pull remote into checked out branch
- [ ] Pull any remore into checked out branch
- [ ] Show upstream has changes

### Push
- [ ] Push locks up the UI. Needs a status indicator and ensure task is on background thread.
- [ ] We can't just do git push "main" it would need to be git push "origin main". "branch -la provides better detail"
- [ ] The push icon seems to only reflect the status of the main branch.
- [ ] The status does not update after a push to indicate there is nothing to push. 

### Conflicts
- [ ] Show files in conflict 
- [ ] Choose which file to pick
- [ ] Look into built in merge conflict resolution (track under diff view features)

### Diff View
- [X] Add dislosure to each file
- [ ] Could use Apple merge tool by default
- [ ] Push line number to top of cell. For a very long wrapped line they can be hard to find.

### Cherry Pick
- [ ] Cherry pick from branch
- [ ] Cherry pick from stash

### Stash 
- [X] Show stashes
  - [X] Show seems to get called 3 times on disclosure
- [ ] Create stash
- [ ] Delete stash

### Fetch

### Branch
- [ ] Add ability to create a branch
- [ ] Add ability to delete a branch
  - [ ] Single branch (currently have to select check box. If only one branch then checkbox should not be needed.)
      - [ ] Update strings to show singular
  - [X] Multiple branchs
    - [ ] Update strings to show plural
- [ ] Use a property for selected branch and not the asterix in the name
- [ ] Figure out git push. 
- [ ] On fresh install there might be an issue with adding a repo. They seem to only work after app restart. 
- [ ] Handle errors when switching a branch results in conflict

### Log
- [ ] Only show first 1000 (or whatever is fast and then add a show more button). 74k takes like 30 seconds. 
  - [ ] Look into using an optimized logger output

### Ignore
- [ ] Implement basic contexual menu. 
- [ ] Create UI for ignore type. file, path, pattern.

### Checkout
- [ ] Checkout remote branch

# TODO BREW
- [ ] Detect where brew is install (/opt or /local)
- [ ] Show installed tools
- [ ] Show available tools
- [ ] Install tool
- [ ] Uninstall tool
- [ ] Show architecture (arm / x86)

# Ideas
  - Direct code edits for minor changes. Similar to how website allows. 
  - Yarn tools
  - Project templates
  - Bundle
  - Project focus. So rather than a git view why not a project view that includes git, yarn, bundle, etc. Some tools would be an exception like brew or when yarn wants to be global

# Notes
- Look into making this a catalyst app. Since we rely heavily on AppKit this isn't straight forward, but moving items to bundles would help.
The reasoning would be that many high level UI features are easier in catalyst and I think Apple will continue that trend. It would also give us
the ability to make some features available on iPad.
- Arguments are escaped via process. This means an argument like "origin main" will fail because the command line sees that as
a single argumnet. Each argument needs to be passed into the array separately. 

# Structure

App
|-- Github
  |-- GithubUI
    |-- Layer to define common git models
      |-- Github Web Api
|-- Git
  |-- GithubUI
    |-- Layer to define common git models
      |-- Git command line
