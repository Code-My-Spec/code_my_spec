defmodule CodeMySpec.Analysis.LostBuildTest do
  @moduledoc """
  A test run that lost its build is a failed run, not a set of test failures.

  The analyzer shares `_build` with the agent, so an agent's own
  `mix compile --force` wipes and rebuilds it while a suite is running and
  modules disappear mid-run. What comes back is
  `module CodeMySpec.Mail.ResendClient is not available` for a module that
  exists and is untouched — 14 of 46 reported failures, on one occasion, with
  nothing saying the agent's own build had caused them.

  It has to be caught rather than reported because it is indistinguishable from
  a real defect: "module is not available" reads as a missing dependency, and
  the natural response is to add code that is already there.

  The signature is reliable in one direction. A genuinely missing module fails
  compilation, so the suite never reaches the point of producing test failures
  — seeing this *among* test results says something about the build, not the
  code.
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

  test "a run reporting an unavailable module fails instead of reporting failures" do
    assert {:error, {:build_changed_mid_run, 1, _}} =
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

  test "a mixed run fails, because the real failures will be re-reported" do
    assert {:error, {:build_changed_mid_run, 1, _}} =
             Runners.from_raw(
               "exunit",
               raw([
                 "Assertion with == failed",
                 "(module CodeMySpec.Mail.ResendClient is not available)"
               ])
             ),
           "one cycle of delay beats sending an agent after code that is already there"
  end

  test "a clean run is unaffected" do
    assert {:ok, %{problems: []}} = Runners.from_raw("exunit", raw([]))
  end
end
