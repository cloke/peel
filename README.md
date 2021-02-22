# TODO GENERAL
- [X] Look at organizing tool specific code into local packages
- [ ] TaskRunner should handle stdError and report back to the user

#  TODO GIT
### General
- [X] Switch branch while file list is selected does not refresh list. Ideally the entire view hiarachy would be repainted and selection removed. 
- [ ] Switch branch and branches should refresh. Again full repaint would be ideal
- [ ] When a file is moved the commit view shows errors on removed files. Status "AD" and "R" are not taken into account.
- [X] Convert file change list to an object that includes status changes and escaped path.
  - [ ] Convert staus to an enum that outlines mod types
- [ ] Training wheels mode. When a destructive action takes place show an "are you sure" modal, but then allow to not show again.
- [ ] Add a timed mechanism for checking for local and remote changes
- [ ] Set a check for minimum git version (>2.23 is required). 
- [ ] Bundle git into project

### Clone
- [ ] ssh
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

### Pull
- [ ] Pull remote into checked out branch
- [ ] Pull any remore into checked out branch
- [ ] Show upstream has changes

### Push
- [ ] Push locks up the UI. Needs a status indicator and ensure task is on background thread.
- [ ] We can't just do git push "main" it would need to be git push "origin main". "branch -la provides better detail"

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
- [ ] Show stashes
  - [ ] Show seems to get called 3 times on disclosure
- [ ] Create stash
- [ ] Delete stash

### Fetch

### Branch
- [ ] Add ability to create a branch
- [ ] Add ability to delete a branch
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
