defmodule CodeMySpec.Analysis.LostBuildTest do
  @moduledoc """
  Whatever an analyzer reports is what gets recorded — no message-content
  heuristic decides a diagnostic isn't real and drops the whole run instead.

  This file used to assert the opposite: a diagnostic matching
  `module ... is not available`, an undefined function on a foreign module,
  or an undefined dunder callback failed the entire run as
  `{:build_changed_mid_run, ...}`, on the theory that a genuinely missing
  module fails compilation, so seeing it among test results could only mean
  the build moved mid-run.

  The theory held for exunit's own test files, which reference modules
  statically. It does not hold for code that resolves a module by name at
  runtime — an MCP tool dispatcher looking up `Tools.Whatever.execute/2`,
  say — where an undefined-function error is a normal, correct runtime
  failure for a module that never existed for a millisecond, not one that
  disappeared mid-run. A spec-first spex exercising a not-yet-implemented
  tool produces exactly that signature. The consequence was not a
  misclassified line: a failed run never reaches `Reconciler.reconcile/3`,
  so Problems for that source never clear, and the copy cannot promote —
  measured on `phx-new-generator`, stuck roughly thirteen hours with a green
  suite. John: "We should not be dropping any diagnostics."

  So every case below that used to expect the run failed and its diagnostics
  discarded now expects the opposite: reported, as a real result, the same
  as any other finding.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  defp raw(messages) do
    %{
      "execution_status" => "failure",
      "exit_status" => 1,
      "output" => "",
      "stats" => %{},
      "diagnostics" =>
        Enum.map(messages, fn message ->
          %{"file" => "test/a_test.exs", "line" => 49, "message" => message}
        end)
    }
  end

  test "a run reporting an unavailable module is reported, not failed" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw(
               "exunit",
               raw([
                 "** (UndefinedFunctionError) function CodeMySpec.Mail.ResendClient.create_domain/1 is undefined (module CodeMySpec.Mail.ResendClient is not available)"
               ])
             )
  end

  test "genuine failures are still reported" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw("exunit", raw(["Assertion with == failed"]))
  end

  test "a mixed run reports every diagnostic, none dropped for another's sake" do
    assert {:ok, %{problems: [_, _]}} =
             Runners.from_raw(
               "exunit",
               raw([
                 "Assertion with == failed",
                 "(module CodeMySpec.Mail.ResendClient is not available)"
               ])
             )
  end

  test "a clean run is unaffected" do
    assert {:ok, %{problems: []}} = Runners.from_raw("exunit", raw([]))
  end

  defp spex_raw(messages, exit_status \\ 1) do
    %{
      "execution_status" => "failure",
      "exit_status" => exit_status,
      "output" => "",
      "diagnostics" =>
        Enum.map(messages, fn message ->
          %{
            "file" => "test/spex/1019_x/criterion_2833_spex.exs",
            "line" => 12,
            "spex" => "criterion_2833",
            "scenario" => "some scenario",
            "message" => message
          }
        end)
    }
  end

  test "a spex run reporting a foreign unavailable module is reported, not failed" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw(
               "spex",
               spex_raw([
                 "** (UndefinedFunctionError) function Jason.Decoder.parse/2 is undefined or private"
               ])
             )
  end

  # The exact signature 17138bc2 reported — a spex run sampling the app
  # mid-restart while a concurrent session's `just refresh` recompiled it.
  # That was a real build race, and it is now reported the same as any other
  # diagnostic: the fix for a message that guesses wrong in one direction is
  # not a message that guesses wrong in the other. A build genuinely racing
  # a spex run is `41753dae`'s and the shared-build-path issue's to fix at
  # the source, not this module's to paper over by discarding results.
  test "a spex run reporting our own module's dunder callback as undefined is reported, not failed" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw(
               "spex",
               spex_raw([
                 "function CodeMySpecWeb.AgentConversationLive.Show.__live__/0 is undefined"
               ])
             )
  end

  test "an ordinary undefined function on one of our own modules is still a genuine failure" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw(
               "spex",
               spex_raw([
                 "function CodeMySpecWeb.AgentConversationLive.Show.handle_event/3 is undefined"
               ])
             )
  end

  test "genuine spex failures are still reported" do
    assert {:ok, %{problems: [_]}} =
             Runners.from_raw("spex", spex_raw(["Assertion with == failed"]))
  end

  test "a clean spex run is unaffected" do
    assert {:ok, %{problems: []}} = Runners.from_raw("spex", spex_raw([], 0))
  end
end
