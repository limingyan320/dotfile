# TEACHER.md Schema

Create `TEACHER.md` at the project root with this compact structure:

```markdown
# Coding Learning Record

## Context
- Project:
- Scenario:
- Goal:
- Current module:

## Recall Items
| Item | Kind | Exact or preferred form | Source | Status |
| --- | --- | --- | --- | --- |

## Topics
| Topic | Source | Explained | Quizzed | Result |
| --- | --- | --- | --- | --- |

## Active Quiz
- Topic: none
- Question: none
- Hint level: 0
- State: none

## Notes
-
```

## Populate Context

- Infer the project name and module from the repository, manifest, file path, and current source.
- Derive the scenario and goal from project documentation or the user's explicit statements.
- Write `unknown` rather than inventing missing context.
- Update `Current module` as the lesson moves through the codebase.
- Use the user's language for free-text descriptions and topic names.

## Update Rows

- Keep one row per recall item and one row per topic; update existing rows instead of appending duplicates.
- Use `contract`, `library-api`, `project-name`, or `concept` in the `Kind` column.
- Use `new`, `learning`, `shaky`, or `recalled` for recall status.
- Use an ISO date (`YYYY-MM-DD`) in `Explained` and `Quizzed`; use `-` when not yet applicable.
- Use `not-tested`, `correct`, `partial`, `incorrect`, or `blocked` for topic results.
- Keep source references short, such as `path/to/file.py:parse_args`.

## Manage Active Quiz

Store only enough information to resume one unfinished question. Increment `Hint level` from 0 through 3. Clear all active-quiz fields back to `none` and `0` when the question is resolved or explain mode replaces it.

## Keep The File Useful

- Preserve user-authored notes.
- Keep `Notes` to concise learning decisions or recurring difficulties.
- Do not copy explanations, full answers, transcripts, credentials, tokens, or private data into the file.
- Do not create extra progress documents or modify ignore rules automatically.
