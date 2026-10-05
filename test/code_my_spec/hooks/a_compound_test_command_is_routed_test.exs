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

  defp decide(command) do
    PreToolUse.decide(
      @scope,
      %{"tool_name" => "Bash", "tool_input" => %{"command" => command}},
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

  test "a test after cd is not routed yet, and says so" do
    log =
      capture_log(fn ->
        assert decide("cd /w && mix test test/a_test.exs") == %{}
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
end
