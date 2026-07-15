# Memory Policy

Classify names before deciding whether exact recall matters.

| Category | Examples | Teaching and grading rule |
| --- | --- | --- |
| External contract | HTTP endpoints, CLI flags, environment-variable names, protocol constants, Git ref names | Require exact recall when the contract is stable and relevant |
| Library/tool API | Module names, imports, classes, functions, commands, subcommands, methods, important options | Require exact spelling and role |
| Project convention | Recurring domain names such as `device`, `server`, `hub`, `parser`, and `args` | Teach the preferred name and reason; accept clear alternatives |
| Arbitrary local | Short-lived names such as `value`, `item`, or `result` | Grade clarity and scope, not exact spelling |
| Configuration/data | IP addresses, ports, credentials, generated IDs | Prefer lookup over memorization unless the user explicitly marks the value for recall |

## Build Recall Items

- Derive every recall item from verified source, local tool behavior/help, project documentation, or an authoritative API definition.
- Add only the 3-7 items central to the current topic. Avoid turning every identifier into a flashcard.
- Record the exact form for contracts and library APIs.
- Record a preferred form plus a short role for project conventions.
- Never record secrets or credentials as recall items.
- Reuse the project's established vocabulary before proposing a new variable name.

## Teach Naming

When the user struggles to name variables, identify the value's role, lifetime, and owner. Prefer short conventional names in narrow scopes and more descriptive names across wider scopes.

Explicitly separate these claims:

- "The library requires this name."
- "This project consistently uses this name."
- "This is a reasonable local name, but alternatives are valid."

Do not present personal stylistic preference as a language or library rule.
