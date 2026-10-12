defmodule CodeMySpec.Hooks.ACompoundTestCommandIsRoutedTest do
  @moduledoc """
  The PreToolUse hook routes the test segment of the commands agents actually
  write, and logs every test decision with the command's shape (test-run
  capture A and G).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias CodeMySpec.Hooks.PreToolUse

  @scope %{active_project_id: "p1", active_working_copy_id: "wc-1"}

  # The decisions log at :info, below the test env's primary level, which
  # neither capture_log's option nor a process level lowers.
  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  defp decide(command, cwd \\ "/w/copy") do
    PreToolUse.decide(
      @scope,
      %{"tool_name" => "Bash", "tool_input" => %{"command" => command}, "cwd" => cwd},
      4004,
      :harness
    )
  end

  defp routed(%{"hookSpecificOutput" => %{"updatedInput" => %{"command" => command}}}),
    do: command

  test "the test segment is routed and its redirect and pipe are kept" do
    log =
      capture_log(fn ->
        command = routed(decide("MIX_ENV=test mix test test/a_test.exs 2>&1 | tail -20"))

        assert command =~ "/api/harnesses/wc-1/analysis/run"
        assert command =~ ~S("args":["test/a_test.exs"])
        assert String.ends_with?(command, " 2>&1 | tail -20")
        refute command =~ "mix test"
      end)

    assert log =~ "mix test/spex routed (shape: piped, redirected)"
  end

  # Claude Code asks a person before any `rm` of a path it cannot resolve, so a
  # routed run that cleaned up a `mktemp` file was denied whenever nobody was
  # at the prompt.
  test "a routed run removes nothing" do
    command = routed(decide("mix spex test/spex/1080_story > out.txt 2>&1"))

    refute command =~ ~r/\brm\b/
    refute command =~ "mktemp"
  end

  # The curl carries `$f` as written, so it was a run of the file `$f` — which
  # found nothing and answered green (2026-10-12).
  test "a segment whose args the shell would expand is not routed" do
    assert decide("f=test/a_test.exs; mix spex $f > out.txt 2>&1") == %{}
    assert decide("mix test `cat files.txt` 2>&1 | tail -5") == %{}
  end

  # Claude Code's removal guard cannot read inside a `sh -c` script, so it
  # refused every routed run in auto mode (2026-10-11).
  test "a routed run is one plain curl, not a shell script" do
    command = routed(decide("mix test test/a_test.exs"))

    assert String.starts_with?(command, "curl -sS --fail-with-body ")
    refute command =~ "sh -c"
  end

  test "a test after cd into this copy is routed, and the cd is kept" do
    command = routed(decide("cd /w/copy/apps/web && mix test test/a_test.exs", "/w/copy"))

    assert String.starts_with?(command, "cd /w/copy/apps/web && curl ")
  end

  test "a relative cd stays inside the copy" do
    assert routed(decide("cd apps/web && mix test", "/w/copy")) =~ "/analysis/run"
    assert decide("cd ../other && mix test", "/w/copy") == %{}
  end

  test "a test after cd into another copy is not routed, and says so" do
    log =
      capture_log(fn ->
        assert decide("cd /w/other && mix test test/a_test.exs", "/w/copy") == %{}
      end)

    assert log =~ "mix test/spex not routed (shape: cd, compound)"
  end

  test "an unparseable test command is not routed, and says so" do
    log =
      capture_log(fn ->
        assert decide("mix test $(git diff --name-only)") == %{}
      end)

    assert log =~ "not routed (shape: unparseable)"
  end

  test "mix compile still routes as a whole command" do
    assert routed(decide("mix compile")) =~ ~S("source":"compiler")
  end

  test "a test from a subagent's worktree is not routed to the copy" do
    params = %{
      "tool_name" => "Bash",
      "tool_input" => %{"command" => "mix test test/a_test.exs"},
      "cwd" => "/w/copy/.claude/worktrees/agent-1",
      "nested_checkout" => "/w/copy/.claude/worktrees/agent-1"
    }

    log = capture_log(fn -> assert PreToolUse.decide(@scope, params, 4004, :harness) == %{} end)

    assert log =~ "not routed (shape: nested_checkout)"
  end

  test "a test after a cd it cannot follow is not routed" do
    assert decide("cd $R && mix test test/a_test.exs", "/w/copy") == %{}
    assert decide("cd /w/other && S=1; mix test test/a_test.exs", "/w/copy") == %{}
  end
end
