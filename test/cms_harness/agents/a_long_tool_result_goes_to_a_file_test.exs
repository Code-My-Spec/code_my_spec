defmodule CmsHarness.Agents.ALongToolResultGoesToAFileTest do
  @moduledoc """
  A result past the cap used to be cut, and what ran past it was gone: a
  coder's `cat a b c` lost `c` and was told only that something was truncated.
  Now it goes to a file outside the checkout that the agent can read back.
  """
  use ExUnit.Case, async: false

  alias Alloy.Message
  alias Alloy.Tool.Executor
  alias CmsHarness.Agents
  alias CmsHarness.Agents.Engine.Impl

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    CmsHarnessTest.Machine.ensure_supervisor()
    id = "agent-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm_rf(Impl.spill_dir(id)) end)
    %{root: root, id: id}
  end

  defp launch(root, id) do
    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "zai",
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    [{engine, _}] = Registry.lookup(CmsHarness.Registry, {:agent, id})
    :sys.get_state(:sys.get_state(engine).alloy)
  end

  defp read(state, path, input \\ %{}) do
    call = %{
      id: "call-#{System.unique_integer([:positive])}",
      name: "read",
      input: Map.put(input, "file_path", path)
    }

    %Message{content: [block]} = Executor.execute_all([call], state.tool_fns, state)
    block.content
  end

  test "is saved whole outside the checkout, and the agent can read it back",
       %{root: root, id: id} do
    File.write!(
      Path.join(root, "big.txt"),
      Enum.map_join(1..1_500, "\n", &"row #{&1} of the file")
    )

    state = launch(root, id)

    notice = read(state, "big.txt")

    assert [_, path] = Regex.run(~r/Full output saved to: (\S+)/, notice),
           "a 30k read came back without a spill notice:\n" <> String.slice(notice, 0, 300)

    assert String.starts_with?(path, Impl.spill_dir(id))
    refute String.starts_with?(path, root), "a spill inside the checkout dirties the tree"
    assert notice =~ "row 1500 of the file"

    # In parts, as the notice says: the whole file is as long as it was.
    assert read(state, path, %{"offset" => 745, "limit" => 10}) =~ "row 750 of the file",
           "the agent was pointed at a file its own Read tool refuses"
  end

  test "an old spill is pruned when the agent starts; a recent one is kept",
       %{root: root, id: id} do
    dir = Impl.spill_dir(id)
    File.mkdir_p!(dir)
    old = Path.join(dir, "old.txt")
    recent = Path.join(dir, "recent.txt")
    File.write!(old, "")
    File.write!(recent, "")
    File.touch!(old, System.os_time(:second) - 2 * 24 * 60 * 60)

    launch(root, id)

    refute File.exists?(old)
    assert File.exists?(recent), "a restarted agent's history still names this file"
  end
end
