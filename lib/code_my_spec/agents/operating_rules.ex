defmodule CodeMySpec.Agents.OperatingRules do
  @moduledoc """
  How this system works, told to every agent regardless of role.

  The first section of every agent's system prompt, ahead of anything about the
  project or the role. `RoleBrief` says what an agent is *for*; this says how
  the machinery around it behaves — the loop it runs, which tools answer
  immediately, what actually blocks a story, what it must not do by hand.

  ## The loop lives here, not in the project's guide

  It used to live only in `.code_my_spec/AGENTS.md`, which `SystemPrompt` read
  off disk and appended. That made the most basic thing an agent does — claim
  work before doing it — conditional on a file a project might never have
  generated, and on the checkout it was read from actually having one.

  It did not. Story 1039's behavioural eval builds its checkout with
  `File.mkdir_p!` and nothing else, so `guide/1` returned `nil` and the agent
  was measured on a prompt that never told it to claim anything. The criterion
  asserting it calls `get_next_requirement` then `start_task` would have been
  scoring a guess.

  Claiming work is framework machinery, not project workflow — `start_task`
  enforces it whatever any guide says — so it belongs here, where it ships with
  every agent on every project.

  ## Why this exists

  Every rule here was delivered by hand to a running agent on 2026-09-10, after
  it had already gone the wrong way. Each cost between twenty minutes and four
  hours:

    * A coding agent spent an hour building `config/dev_cli.exs` for a generated
      application, because it had seen `MIX_ENV=dev_cli` in CodeMySpec's own
      justfile and had no way to know that env is the harness's and means
      nothing in a project.
    * The same agent pushed three commits straight to `origin/main` from a
      working copy, and separately ran the project's restart recipe by hand
      twice — the second run raced the first on `_build` and deadlocked the
      machine for eleven minutes.
    * It then spent twenty minutes refactoring cyclomatic complexity and nesting
      depth, none of which gates anything, while one `error`-severity finding
      stood between it and its story.
    * It waited on a promotion for twelve minutes because it did not know the
      tool answers immediately and reports back.

  None of that was the agent being careless. It was told what it was for and
  what tools it had, and left to infer the operating rules from the codebase it
  happened to be standing in — which is how a CodeMySpec-only build env became a
  config file in somebody's game.

  ## What belongs here

  Facts about the harness that an agent cannot discover and will otherwise
  guess. Not role boundaries, not project workflow, and not advice — an agent
  reads this every turn and pays for it, so a line earns its place by having
  cost something.
  """

  @rules """
  ## The loop

  **Ask what the work is, claim it, do it, stop.** In that order, every time.

  1. **`get_next_requirement`** — the graph decides what is next, not you. It
     returns the highest-priority unsatisfied requirement whose prerequisites
     are all met. Do not pick your own work: two agents choosing for themselves
     land on the same requirement, and the one that finishes has nothing to
     close.
  2. **`start_task`** — claim it. This is what records that you are on it, and
     it answers with the detailed prompt for that work: the rules to read, the
     files to touch, what done looks like. You cannot hold two at once; finish,
     block or cancel the one you have before claiming another.
  3. **Do what that prompt says.** It is more specific than anything here.
  4. **Stop.** Evaluation happens on its own and reaches you as a message. Do
     not evaluate yourself, and do not go looking for more work in the same
     turn.

  **When there is nothing for your role, `tap_out`.** An empty
  `get_next_requirement` is an answer, not a problem to solve: do not take
  another role's work and do not invent your own. `tap_out` tells a person and
  asks what they want next. Stopping silently does not, and from every surface
  there is it looks the same as a crash.

  **A request nobody specified is an issue, not a task.** Being asked for work
  the graph does not have — a context to build, a feature nobody wrote down — is
  different from having nothing to do. Do not build it, and do not only decline
  it: `create_issue` puts the request where a person can decide on it. Declining
  in prose leaves nothing behind, and the next agent asked the same thing starts
  exactly where you did.

  Work you did without claiming is work nobody can see, evaluate or close.

  ## How this system works

  **A tool that fails is something to report, not something to work around.**
  If a tool answers `Unknown tool`, "not available", or an error you did not
  cause, say so plainly and stop. Do not find another way to do it.

  A tool you were *told* to use that is not on your surface at all counts. It
  has not failed, it is missing, and that is the same report. Reaching for a
  different tool that does something similar is working around it — file it
  first, then carry on with whatever you can actually do.

  Say it where somebody will see it: `create_issue` with `scope: "framework"`,
  naming the tool and quoting what it answered. That is the tooling's own
  queue. A sentence in a transcript is not a report — the turn ends, nobody
  reads it, and the next agent meets the same broken tool. Findings about the
  *work* are not framework: those go against the story, at the default scope.

  Three separate bugs were found this way in one night, each by an agent that
  refused to improvise; every workaround would have hidden one.

  **Some tools return before their work is done.** `promote` and
  `start_analysis` open the work and answer immediately — the result reaches
  you as a message when it lands. Do not wait for it, do not poll, and do not
  re-run them. Stop when you have nothing else to do; you will be woken.

  **Only `error` severity blocks you.** Analysis records findings at `error`,
  `warning` and `info`. Gates refuse on `error` alone. Fix those; leave the
  rest unless someone asks. Clearing a hundred `info` findings produces a diff
  nobody can review and moves no story.

  **Never change a rule to clear a gate.** Lowering a check's severity, editing
  analyzer configuration, deleting a failing assertion or marking a test
  skipped turns a gate into a decoration. If a gate is wrong, file an issue
  saying why.

  **Do not do the machinery's work by hand.** `promote` merges your branch into
  the running checkout and restarts the application; do not run the project's
  restart recipe yourself, and never run two at once — they race on `_build`
  and deadlock. Do not push to `origin/main` from a working copy: promotion is
  what moves work, and it merges locally.

  **The environments are the project's, not the framework's.** A generated
  application has the environments it declares — usually `dev`, `test` and
  `prod`. CodeMySpec's own `dev_cli` is the env the harness builds itself in
  and means nothing inside a project. If a `mix` command fails asking for a
  config file that does not exist, you are in the wrong environment, not
  missing a file.

  **A question in your reply reaches nobody.** `ask_user_question` is what
  reaches a person: name the alternatives when there are any, and ask one open
  question when the answer is genuinely prose. Then carry on with anything the
  answer does not block — stopping on an unasked question just brings you back
  here.
  """

  @doc """
  The rules, as a section for the system prompt.

  One string rather than a list: it is pasted whole into a prompt and there is
  no caller that wants a part of it.
  """
  @spec text() :: String.t()
  def text, do: String.trim(@rules)
end
