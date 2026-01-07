# Async/Await Assessment & Recommendation

**Date**: January 6, 2026  
**Question**: Should we do a quick pass at async stuff or continue with the modernization plan?  
**Answer**: **Continue with the plan** ✅

## Assessment Summary

### Current State by Package

#### Git Package ✅ Fully Modernized
- ✅ Repository: @Observable with @MainActor methods
- ✅ ViewModel: @Observable with proper async/await
- ✅ Branch: @Observable (just verified)
- ✅ No Combine dependencies
- ✅ No manual DispatchQueue.main calls
- ✅ No manual MainActor.run wrappers
- ✅ Proper .task(id:) usage where needed

#### Github Package ⚠️ Partially Modernized
- ✅ Repository switching bug fixed (.task(id:) added)
- ⚠️ ViewModel may still use old patterns (needs review)
- ✅ No major async/await issues found
- 🔄 Will be addressed in upcoming modernization

#### Brew Package ❌ Needs Modernization
Found old patterns:
```swift
// Combine usage
import Combine
class SearchResults: ObservableObject {
  @Published var isSearching = false
  @Published var filtered = [String]()
  @Published var searchText: String = ""
}

// Manual DispatchQueue.main
DispatchQueue.main.async {
  self.name = decoded.name ?? ""
  self.desciption = decoded.description ?? ""
}

// Combine debounce
.debounce(for: .seconds(0.3), scheduler: DispatchQueue.main)
```

### Remaining Async Issues

**Total DispatchQueue.main calls**: 7 (all in Brew package)
**Total MainActor.run calls**: 0 ✅
**Total manual Task wrapping**: Minimal, mostly appropriate

## Recommendation: Continue with Plan

### Why Continue with Plan vs. Quick Pass

1. **Systematic > Ad-hoc**
   - The modernization plan addresses all async issues naturally
   - Converting to @Observable automatically eliminates Combine
   - @MainActor on classes eliminates manual DispatchQueue calls

2. **Issues are Localized**
   - Git package: ✅ Already clean
   - Github package: ⚠️ Minor issues only
   - Brew package: ❌ All issues concentrated here

3. **Next Logical Step**
   - Plan says: "Option B: Convert Brew Package"
   - This will fix all 7 DispatchQueue.main calls
   - This will remove all Combine usage in Brew
   - Follows same successful pattern we used for Git

4. **No Critical Bugs**
   - App builds successfully ✅
   - No race conditions identified
   - No obvious async/await misuse
   - Repository switching bug already fixed ✅

### What We Just Completed

✅ **Git Package Full Modernization**
- Repository: ObservableObject → @Observable
- ViewModel: ObservableObject → @Observable  
- Branch: ObservableObject → @Observable
- Removed all Combine usage
- Added proper @MainActor annotations
- Eliminated all manual threading code

✅ **Github Repository Switching Bug Fix**
- Changed .onAppear → .task(id: repository.id)
- Fixed in all 4 tab views (PRs, Commits, Issues, Actions)

## Next Steps (Following the Plan)

### Immediate: Option B - Convert Brew Package

**Priority**: HIGH  
**Complexity**: Medium (similar to Git package)  
**Impact**: Will fix all remaining DispatchQueue.main calls

Steps:
1. Convert `SearchResults` from ObservableObject to @Observable
2. Convert `DetailView.ViewModel` from ObservableObject to @Observable
3. Remove Combine imports
4. Replace `.debounce()` with async/await pattern
5. Add @MainActor where appropriate
6. Remove manual DispatchQueue.main calls
7. Update view layer (@ObservedObject → @State, etc.)

### After Brew: Option C - Convert Github Package

**Priority**: MEDIUM  
**Complexity**: Higher (OAuth, network layer)  
**Impact**: Complete modernization

Steps:
1. Review Github.ViewModel
2. Convert to @Observable if needed
3. Ensure proper @MainActor usage
4. Update GithubUI components

## Pattern for Brew Modernization

Based on successful Git conversion:

```swift
// BEFORE (Brew DetailView.ViewModel)
import Combine
class ViewModel: TaskRunnerProtocol, ObservableObject {
  @Published var outputStream = [String]()
  @Published var desciption = ""
  
  func load() {
    DispatchQueue.main.async {
      self.name = decoded.name ?? ""
    }
  }
}

// AFTER (Modern Pattern)
import Observation
@MainActor
@Observable
class ViewModel: TaskRunnerProtocol {
  var outputStream = [String]()
  var desciption = ""
  
  func load() async {
    // Already on MainActor, direct assignment
    self.name = decoded.name ?? ""
  }
}
```

## Conclusion

**Recommendation**: Continue with the modernization plan - specifically **Option B: Convert Brew Package**

**Reasoning**:
- Issues are concentrated in Brew package
- Plan naturally addresses all async/await issues
- Following systematic approach = less risk
- Git package modernization was successful using this approach
- No critical bugs requiring immediate attention

**Time Estimate**: 
- Brew package: ~30-45 minutes (similar to Git)
- Github package: ~1-2 hours (more complex)

---

**Decision**: Proceed with Brew package modernization following the plan ✅
