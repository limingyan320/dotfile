# TEACHER.md Schema

Create `TEACHER.md` at the project root. A topic may concern source code, a developer tool, a command, an error, or a project workflow; it does not need a repository file reference.

```markdown
# Software Engineering Learning Record

## Context
- Project:
- Scenario:
- Goal:
- Current area:
- Current subject:

## Recall Items
| Item | Kind | Exact or preferred form | Context / reference | Status |
| --- | --- | --- | --- | --- |

## Topics
| Topic | Context / reference | Explained | Quizzed | Result |
| --- | --- | --- | --- | --- |

## Misconceptions

### M001: Short topic
- Initial thought:
- Why it was wrong:
- Correct answer:
- Why the correct answer holds:
- Evidence:
- First recorded: YYYY-MM-DD
- Repeat count: 0
- Repeat history: -
- Status: corrected

## Active Quiz
- Topic: none
- Question: none
- Hint level: 0
- State: none

## Notes
-
```

## Populate Context

- Infer the project from the repository, manifest, current directory, and user statements.
- Derive the scenario and goal from project documentation or the user's explicit statements.
- Use `Current area` for categories such as `source code`, `Git`, `Shell`, `packaging`, `build`, or `deployment`.
- Use `Current subject` for the specific file/symbol, command, error, or workflow.
- Write `unknown` rather than inventing missing context.
- Use the user's language for free-text descriptions and topic names.

## Record References

- Use a short source location for code, such as `path/to/file.py:parse_args`.
- Use a precise context for tools, such as `Git: working tree vs index`, `command: git reset`, or an official documentation URL.
- Prefer evidence that can be checked again later: source code, local command output, `--help`, a manual page, or authoritative documentation.

## Update Rows

- Keep one row per recall item and one row per topic; update existing rows instead of appending duplicates.
- Use `contract`, `library-api`, `tool-api`, `project-name`, or `concept` in the `Kind` column.
- Use `new`, `learning`, `shaky`, or `recalled` for recall status.
- Use an ISO date (`YYYY-MM-DD`) in `Explained` and `Quizzed`; use `-` when not yet applicable.
- Use `not-tested`, `correct`, `partial`, `incorrect`, or `blocked` for topic results.

## Record Misconceptions

- Create an entry only when the user explicitly states a wrong hypothesis, guess, explanation, or quiz answer. Do not infer an unspoken belief.
- Preserve the user's original meaning. Quote it concisely when possible; summarize only when necessary.
- Explain the causal flaw under `Why it was wrong`; do not merely label the thought incorrect.
- Make `Correct answer` self-contained enough to review later without the original conversation.
- Explain the mechanism or evidence under `Why the correct answer holds`.
- Include a reproducible source under `Evidence`, such as a symbol, command output, help text, or official documentation.
- Match repeated mistakes by concept. Reuse the existing ID, increment `Repeat count`, append the new date and quiz result to `Repeat history`, and set status to `repeated`.
- Set status to `recalled` only after the user answers the same concept correctly without answer-bearing hints.
- Keep separate misconceptions separate even when they occurred in the same answer.

## Manage Active Quiz

Store only enough information to resume one unfinished question. Increment `Hint level` from 0 through 3. Clear all active-quiz fields back to `none` and `0` when the question is resolved or explain mode replaces it.

## Migrate Existing Files

When an existing `TEACHER.md` uses the older schema, preserve all content. Add `Current area`, `Current subject`, and `## Misconceptions` only when absent. Do not rename or delete existing headings merely to match the latest template.

## Keep The File Useful

- Preserve user-authored notes.
- Store concise correction records, not full transcripts or lengthy tutorials.
- Never store credentials, tokens, private values, or secrets in examples.
- Do not create extra progress documents or modify ignore rules automatically.
