# TODO GENERAL
- [ ] Look at organizing tool specific code into local packages

#  TODO GIT
### General
- [ ] Switch branch while file list is selected does not refresh list. Ideally the entire view hiarachy would be repainted and selection removed. 
- [ ] Switch branch and branches should refresh. Again full repaint would be ideal
- [ ] When a file is moved the commit view shows errors on removed files. Status "AD" and "R" are not taken into account.
- [ ] Convert file change list to an object that includes status changes and escaped path.
- [ ] Training wheels mode. When a destructive action takes place show an "are you sure" modal, but then allow to not show again.

### Commits
- [ ] Require commit message before button is enabled
- [X] Stage files
- [X] Unstage files
- [ ] Amend
- [ ] The file list of commits shows quotes
- [ ] Revert file
- [ ] Revert all files

### Pull
- [ ] Pull remote into checked out branch
- [ ] Pull any remore into checked out branch
- [ ] Show upstream has changes

### Push
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

### Ignore
- [ ] Implement basic contexual menu. 
- [ ] Create UI for ignore type. file, path, pattern.

# TODO BREW

# Ideas
  - Add a better git ignore editor
  - Cherry pick
  - Direct code edits for minor changes. Similar to how website allows. 
  - Yarn tools
  - Project templates
  - Bundle
  - Project focus. So rather than a git view why not a project view that includes git, yarn, bundle, etc. Some tools would be an exception like brew or when yarn wants to be global

# Notes
- Arguments are escaped via process. This means an argument like "origin main" will fail because the command line sees that as
a single argumnet. Each argument needs to be passed into the array separately. 
