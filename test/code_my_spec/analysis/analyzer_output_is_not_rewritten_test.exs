defmodule CodeMySpec.Analysis.AnalyzerOutputIsNotRewrittenTest do
  @moduledoc """
  Scenarios for `.code_my_spec/rules/analysis_output_fidelity.md`.

  One per source: given a raw analyzer payload carrying real, distinctive
  tool output, `Runners.from_raw/2` — the one function a harness's reported
  result and a local run both funnel through — has to hand that output back
  unmodified. Not a count, not a line reformatted from the parsed
  diagnostics, not a placeholder.

  Compiler and credo were both wrong before `analysis_output_fidelity.md`
  landed: raw stdout was captured at the shell-out (`Compile.execute/1`,
  `CredoRun.execute/2`) and then discarded — `summarize/3` always
  synthesized `output` from `format_problem_lines/1`, and the wire contract
  from a light harness had no `"output"` field for compiler at all. exunit
  was already correct; kept here so a future change cannot regress it
  without a red test naming it.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  describe "compiler" do
    test "the compiler's own text reaches the agent, not a reformatted diagnostic count" do
      raw_output = """
      Compiling 3 files (.ex)

      warning: variable "unused" is unused
        lib/example.ex:12

      Generated code_my_spec app
      """

      raw = %{
        "exit_status" => 1,
        "diagnostics" => [
          %{"file" => "lib/example.ex", "line" => 12, "severity" => "warning", "message" => "variable \"unused\" is unused"}
        ],
        "diagnostics_available" => true,
        "output" => raw_output
      }

      assert {:ok, result} = Runners.from_raw("compiler", raw)
      assert result.output == raw_output

      refute result.output =~ "warnings:",
             "the real compiler output was replaced with a synthesized count line"
    end
  end

  describe "credo" do
    test "credo's own JSON reaches the agent, not a per-issue line rebuilt from it" do
      raw_output =
        Jason.encode!(%{
          "issues" => [
            %{
              "check" => "Credo.Check.Readability.ModuleDoc",
              "filename" => "lib/example.ex",
              "line_no" => 1,
              "message" => "Modules should have a @moduledoc tag.",
              "priority" => 1
            }
          ]
        })

      raw = %{
        "exit_status" => 1,
        "diagnostics" => [
          %{
            "check" => "Credo.Check.Readability.ModuleDoc",
            "filename" => "lib/example.ex",
            "line_no" => 1,
            "message" => "Modules should have a @moduledoc tag.",
            "priority" => 1
          }
        ],
        "output" => raw_output
      }

      assert {:ok, result} = Runners.from_raw("credo", raw)
      assert result.output == raw_output

      refute result.output =~ ~r/^lib\/example\.ex:1 \[/,
             "the real credo JSON was replaced with a formatted problem-line summary"
    end
  end

  describe "exunit" do
    test "exunit's own dots-and-summary reach the agent unmodified" do
      raw_output = """
      ..F..

      1) test something fails (MyTest)
         assertion failed

      Finished in 0.1 seconds
      5 tests, 1 failure
      """

      raw = %{
        "exit_status" => 1,
        "execution_status" => "failure",
        "output" => raw_output,
        "stats" => %{"tests" => 5, "failures" => 1},
        "diagnostics" => [
          %{"file" => "test/my_test.exs", "line" => 4, "message" => "assertion failed"}
        ]
      }

      assert {:ok, result} = Runners.from_raw("exunit", raw)
      assert result.output == raw_output
    end
  end

  describe "spex" do
    test "spex's own output reaches the agent, not a per-scenario line rebuilt from failures" do
      raw_output = """
      .F.

      ── criterion 9999: a made-up scenario fails ──
      assertion failed

      1 test, 1 failure
      """

      raw = %{
        "exit_status" => 1,
        "output" => raw_output,
        "diagnostics" => [
          %{
            "spex" => "made-up spex",
            "scenario" => "a made-up scenario",
            "file" => "test/spex/9999_made_up/criterion_9999_spex.exs",
            "line" => 42,
            "message" => "assertion failed"
          }
        ]
      }

      assert {:ok, result} = Runners.from_raw("spex", raw)
      assert result.output == raw_output

      refute result.output =~ "made-up spex —",
             "the real spex output was replaced with a formatted problem-line summary"
    end
  end
end
