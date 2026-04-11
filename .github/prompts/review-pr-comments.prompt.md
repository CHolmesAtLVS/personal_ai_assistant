---
name: review-pr-comments
description: Review a PR, address all open review comments, and resolve conversations.
---

A PR link or number will be provided. If it's not, ask.  Using the GitHub CLI and tools available:

1. Fetch the PR details, including all open review comments and review threads.
2. For each open (unresolved) review comment or thread:
   - Understand the concern raised.
   - Make the requested or appropriate code change in the relevant file(s).
   - Reply to the comment thread to explain the change made, then resolve the conversation.
3. After all comments are addressed:
   - Confirm no open review threads remain.
   - Summarize the changes made and which comments they addressed.

At any point during this process:
- If a comment is ambiguous or requires context you don't have, ask the user before making a change.
- If you encounter security issues, breaking changes, architectural concerns, or anything else critical surfaced during review, call it out explicitly before proceeding and require confirmation.

The PR to review: 
