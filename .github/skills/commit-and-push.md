# Skill: Commit and Push Local Changes

Goal: Safely commit and push local changes.

## When to use
- User asks to commit/push or there are local changes blocking workflow.

## Steps
1. git status -sb
2. Review diff if needed.
3. Stage changes:
   - git add -A
4. Commit with a clear message:
   - git commit -m "<message>"
5. Push:
   - git push

## Notes
- If there are stashes, confirm whether to apply them first.
