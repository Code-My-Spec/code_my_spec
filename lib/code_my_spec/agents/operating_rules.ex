defmodule CodeMySpec.Agents.OperatingRules do
  @moduledoc """
  How this system works, told to every agent regardless of role.

  `RoleBrief` says what an agent is *for*. This says how the machinery around
  it behaves — which tools answer immediately, what actually blocks a story,
  what an agent must not do by hand. Neither is the project's workflow; that is
  `.code_my_spec/AGENTS.md` and it is appended separately.

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
  ## How this system works

  **A tool that fails is something to report, not something to work around.**
  If a tool answers `Unknown tool`, "not available", or an error you did not
  cause, say so plainly and stop. Do not find another way to do it. Three
  separate bugs were found this way in one night, each by an agent that
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

  **A question in your reply reaches nobody.** Use `ask_user_question` when
  there are alternatives to choose between, `send_message` when the answer is
  genuinely prose. Then carry on with anything the answer does not block —
  stopping on an unasked question just brings you back here.
  """

  @doc """
  The rules, as a section for the system prompt.

  One string rather than a list: it is pasted whole into a prompt and there is
  no caller that wants a part of it.
  """
  @spec text() :: String.t()
  def text, do: String.trim(@rules)
end
