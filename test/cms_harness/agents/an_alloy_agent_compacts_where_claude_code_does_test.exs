defmodule CmsHarness.Agents.AnAlloyAgentCompactsWhereClaudeCodeDoesTest do
  @moduledoc """
  Alloy budgets compaction against the model's context window, and it knows
  Sonnet 5 and Opus 5.5 as 1M-token models, so an agent compacted only near a
  million. Team 4's Claude Code sessions ran 400k-960k of context per call
  while terminal Claude Code sessions on the same model stayed under ~190k
  (measured 2026-10-19). The harness gives every Alloy agent the budget Claude
  Code works within. A compaction rewrites the history, so the next call to a
  CLI provider goes out fresh with the compacted transcript
  (`AlloyClaudeCode.Session`).
  """
  use ExUnit.Case, async: true

  alias Alloy.Agent.Config
  alias CmsHarness.Agents

  @moduletag :tmp_dir

  setup do
    CmsHarnessTest.Machine.ensure_supervisor()
    :ok
  end

  test "a 1M-window model is budgeted for compaction at 200k, not a million", %{tmp_dir: root} do
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "claude-code",
        "model" => "claude-sonnet-5",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, id})
    config = Config.from_opts(:sys.get_state(engine).alloy_opts)

    assert config.max_tokens == 200_000
    assert config.max_tokens - config.compaction.reserve_tokens < 200_000
  end
end
