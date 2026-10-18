defmodule CmsHarness.Agents.AQaFixtureUnderScratchIsReadableBackTest do
  @moduledoc """
  f72b7ba3: QA builds disposable fixtures (a mock server, its log) through
  `bash` -- a guardrail, not a sandbox, so it can write anywhere -- and then
  could not read them back: the read tool only ever allowed the working copy
  and the tool-result spill directory, refusing an ad hoc `mktemp` path under
  `/private/tmp` with "outside allowed directories". `scratch_dir/1` is now a
  third allowed path, advertised to the agent in its own system prompt, so a
  fixture built there is one the same agent can read back.
  """
  use ExUnit.Case, async: true

  alias Alloy.Agent.Config
  alias Alloy.Agent.State
  alias Alloy.Message
  alias Alloy.Tool.Executor
  alias CmsHarness.Agents
  alias CmsHarness.Agents.Engine.Impl

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    CmsHarnessTest.Machine.ensure_supervisor()
    id = "agent-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Impl.scratch_dir(id)) end)
    %{root: root, id: id}
  end

  defp launch(root, id) do
    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "zai",
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "qa"
      })

    on_exit(fn -> Agents.halt(id) end)
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, id})
    State.init(Config.from_opts(:sys.get_state(engine).alloy_opts))
  end

  defp read(state, path) do
    call = %{
      id: "call-#{System.unique_integer([:positive])}",
      name: "read",
      input: %{"file_path" => path}
    }

    %Message{content: [block]} = Executor.execute_all([call], state.tool_fns, state)
    block.content
  end

  test "a fixture written under scratch_dir is readable back", %{root: root, id: id} do
    dir = Impl.scratch_dir(id)
    File.mkdir_p!(dir)
    fixture = Path.join(dir, "proxy.log")
    File.write!(fixture, "proxy exited before its readiness marker appeared\n")

    state = launch(root, id)

    result = read(state, fixture)

    refute result =~ "outside allowed directories",
           "a fixture under its own scratch_dir was refused: #{result}"

    assert result =~ "proxy exited before its readiness marker appeared"
  end

  test "a fixture outside both the checkout and scratch_dir is still refused", %{
    root: root,
    id: id
  } do
    unrelated = Path.join(System.tmp_dir!(), "not-this-agents-scratch-#{id}.log")
    File.write!(unrelated, "not reachable")
    on_exit(fn -> File.rm(unrelated) end)

    state = launch(root, id)

    result = read(state, unrelated)

    assert result =~ "outside allowed directories",
           "the sandbox boundary this fix relies on no longer holds: #{result}"
  end

  test "the agent's own system prompt names its scratch_dir", %{root: root, id: id} do
    state = launch(root, id)

    assert state.config.system_prompt =~ Impl.scratch_dir(id)
  end
end
