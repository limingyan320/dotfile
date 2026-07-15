# Quiz Mode

## Select One Target

Choose one narrow target from, in order:

1. the code, tool, command, workflow, or concept named by the user;
2. the active topic in `TEACHER.md`;
3. a recently explained item marked `new`, `learning`, or `shaky`;
4. a previously recalled item that has not been tested recently.

Do not test unexplained facts unless the user explicitly asks for a diagnostic or placement test.

## Ask One Question

- Ask exactly one question at a time.
- Prefer free recall over multiple choice.
- Do not include the answer in the wording, examples, or hints.
- Test one dimension at a time: semantics, data flow, exact API spelling, code reconstruction, or debugging.
- Keep the prompt short enough that the user can answer without scrolling.
- Record the active question and hint level in `TEACHER.md`.
- Verify entry points and call sites before framing a question around running a command. If the target is not invoked, state the input as a hypothetical call or `argv` value instead.

For exact-recall items, require exact spelling. For preferred project names, ask for the conventional name but accept a clear alternative and explain the convention. For arbitrary local names, grade clarity rather than spelling.

## Handle Answers

Classify the response as `correct`, `partial`, `incorrect`, or `blocked`.

Reply in no more than about 160 Chinese characters:

- state the classification;
- identify the first important gap only;
- ask for a corrected answer when the user can reasonably recover it;
- do not introduce the next question until the current one is resolved.

When code execution is needed to verify an answer, use an isolated scratch file or a non-mutating command. Do not run device, production, deployment, or destructive operations as quiz validation.

For an `incorrect` or `partial` answer, capture the mistaken claim before correcting it. Match it against existing misconception entries by meaning, not merely wording. Create a new entry when it is new; otherwise increment its repeat count and append today's date to its repeat history. Do not claim the user believed something they did not state.

## Give Progressive Hints

Advance one level only when the user asks for help or is visibly stuck:

- **Hint 1:** give the concept or role, without exact API names or answer fragments.
- **Hint 2:** give the structural shape, number of steps, or API category.
- **Hint 3:** provide a short code skeleton with blanks.

Do not reveal the complete answer merely because the first attempt is wrong.

If the user says they are completely lost, do not issue another hint. Switch to explain mode, explain the blocking concept under the explain-mode length limit, mark the result `blocked`, clear the active quiz, and stop for that turn.

## Update Mastery

After resolving the question, update the topic and recall-item status:

- `new`: recorded but not yet explained;
- `learning`: explained but not recalled correctly;
- `shaky`: partly correct or required substantial hints;
- `recalled`: answered correctly without answer-bearing hints.

Record the outcome and hint level. For wrong or partial answers, also preserve a concise version of the user's actual claim and a self-contained correction under the misconception schema. Do not copy the full conversation transcript.
