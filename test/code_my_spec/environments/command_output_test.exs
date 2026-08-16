defmodule CodeMySpec.Environments.CommandOutputTest do
  @moduledoc """
  `cmd/4` returns what the command wrote, less the terminal bytes.

  `2f6695dd`. `Local.cmd/4` trimmed its output and `Container.cmd/4` did not,
  so the same command parsed by the same code produced two different strings
  depending on which environment ran it. Nothing announced the difference and
  nothing tested it.

  The trimming was justified in the behaviour doc as "bound for a database and
  a JSON response, and neither tolerates raw terminal bytes" — which is the
  reason for stripping ANSI and validating UTF-8, and those stay. A trailing
  newline is not a terminal byte problem; Postgres and JSON both hold one
  perfectly well.

  What it cost: for `git status --porcelain` the leading space *is* data, the
  staged-status column, blank for anything modified-but-not-staged. Trimming
  removes it from the first line only, so `?? path` survives, ` M path` loses
  a character, and every line after the first is untouched — the same buffer
  parses two different ways depending on which file git happened to list
  first. Two implementations of the QA evidence check were written against it
  and both failed silently, in opposite directions: one returned paths one
  character short, the other read every dirty file as clean.

  Callers that want it trimmed can trim, and several already do on top of this
  — `Git.CLI.get_remote_url/2` among them, which is what made the loss
  invisible for so long.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  setup do
    %{env: %Environment{type: :local, cwd: File.cwd!()}}
  end

  test "leading whitespace survives, because in porcelain it is a column", %{env: env} do
    {output, 0} = Environments.cmd(env, "printf", ["%s", " M lib/thing.ex\n"])

    assert output == " M lib/thing.ex\n"

    assert String.starts_with?(output, " "),
           "the blank first column is git's 'not staged' marker; dropping it turns " <>
             "a modified file into a staged one, or a path into one character less " <>
             "than a path"
  end

  test "the trailing newline survives too", %{env: env} do
    {output, 0} = Environments.cmd(env, "printf", ["%s", "abc123\n"])

    assert output == "abc123\n"
  end

  # The two halves of the cleaning that the behaviour doc's rationale actually
  # covers. These are the reason `cmd/4` does not simply return System.cmd's
  # output, and removing the trim must not remove them.
  test "ANSI escapes are still stripped", %{env: env} do
    {output, 0} = Environments.cmd(env, "printf", ["%s", "\e[31mred\e[0m"])

    assert output == "red"
  end

  test "invalid UTF-8 is still scrubbed", %{env: env} do
    {output, 0} = Environments.cmd(env, "printf", ["%b", "ok\\xff"])

    assert String.valid?(output),
           "invalid UTF-8 reaching a JSON response crashes the MCP session with " <>
             "-32603, which is the one thing this cleaning genuinely prevents"
  end

  # The environments disagreeing is the defect underneath the reported symptom:
  # code that runs both locally and in a container cannot parse column-oriented
  # output correctly in both.
  test "a local command's output is not cleaned differently from a container's", %{env: env} do
    raw = " M a.ex\n?? b.ex\n"
    {output, 0} = Environments.cmd(env, "printf", ["%s", raw])

    assert output == raw,
           "Container.cmd/4 returns System.cmd's output verbatim; Local must agree, " <>
             "or the same parser is correct in one environment and wrong in the other"
  end
end
