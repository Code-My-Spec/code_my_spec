defmodule CodeMySpec.Analysis.ASpecFirstSpexIsNotALostBuildTest do
  @moduledoc """
  A spec-first spex naming a tool nobody has implemented yet is a real,
  reportable failure — not a build that changed mid-run.

  The real payload from `phx-new-generator`, 2026-09-15: a spex scenario for
  story 1013 (the main agent reading its own agents' conversations, written
  spec-first) called an MCP tool that had not been built yet,
  `CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation`. The removed
  `lost_build?/1` heuristic read "module ... is not available" as proof a
  build raced this run and failed the whole thing, discarding every
  diagnostic in it. The module had not disappeared mid-run — it had never
  existed for a millisecond, because resolving a module by name at runtime
  (an MCP tool dispatcher, here) is a compile-time warning in Elixir, not an
  error, so the suite compiled and ran fine and only failed where that one
  path executed.

  A failed run never reaches `Reconciler.reconcile/3`, so this working
  copy's spex Problems never cleared past whatever last completed sweep
  predated the change, and `serve/2` being downgrade-only meant nothing
  self-corrected. Promotion gates on a fresh spex run at the current commit.
  The copy sat unable to promote for roughly thirteen hours with a green
  suite, and nothing said why.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  test "a not-yet-built tool named by a spec-first spex is reported as a real failure" do
    raw = %{
      "execution_status" => "failure",
      "exit_status" => 1,
      "output" => "",
      "diagnostics" => [
        %{
          "file" =>
            "test/spex/1013_the_main_agent_reads_its_own_agents_conversations/criterion_x_spex.exs",
          "line" => 40,
          "spex" => "criterion_x",
          "scenario" => "the main agent reads a running agent's conversation",
          "message" =>
            "** (UndefinedFunctionError) function CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation.execute/2 is undefined (module CodeMySpec.McpServers.MainAgent.Tools.ReadAgentConversation is not available)"
        }
      ]
    }

    assert {:ok, %{problems: [problem]}} = Runners.from_raw("spex", raw)

    assert problem.file_path =~
             "1013_the_main_agent_reads_its_own_agents_conversations"
  end
end
