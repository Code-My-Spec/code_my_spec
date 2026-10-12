defmodule CmsHarness.Agents.AnHttpAgentsTurnGetsTheEnginesCeilingTest do
  @moduledoc """
  Alloy bounds a whole loop by `timeout_ms` (two minutes by default) and sets
  every request's receive timeout to what is left of it. A DeepSeek coder that
  ran three test files spent the two minutes, and its next request was given a
  second and failed `:timeout` — the turn was lost, retry included.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents

  @moduletag :tmp_dir

  setup do
    CmsHarnessTest.Machine.ensure_supervisor()
    :ok
  end

  test "an HTTP provider's loop runs as long as the engine lets a turn run", %{tmp_dir: root} do
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "deepinfra",
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, id})
    alloy = :sys.get_state(:sys.get_state(engine).alloy)

    assert alloy.config.timeout_ms == :timer.minutes(30)
  end
end
