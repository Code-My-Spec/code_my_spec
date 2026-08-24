defmodule CmsHarness.AgentsTest do
  @moduledoc """
  What this machine does when the server asks it to bring an agent up.

  An agent is a supervised process now, not a detached OS one, so the failures
  worth naming changed with it. There is no engine binary to be missing and no
  process group to signal; what can go wrong is a checkout that is not there, a
  provider nobody knows, and a credential that arrived without the field its
  provider needs.

  Starting an agent makes no model call — `Alloy.Agent.Server` only reaches a
  provider when something chats to it — so the whole start/stop lifecycle is
  exercised here for real, with a credential that is never used.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents
  alias CmsHarness.Agents.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Through `Machine`, not `start_supervised!`. A supervisor linked to this
    # test dies with it, and anything that started an agent under it is then
    # looking in a tree that no longer exists — which only shows up in a full
    # run, and passes twenty times in isolation.
    CmsHarnessTest.Machine.ensure_supervisor()

    %{root: tmp_dir}
  end

  defp request(root, overrides \\ %{}) do
    Map.merge(
      %{
        "agent_id" => "agent-#{System.unique_integer([:positive])}",
        "provider" => "zai",
        # Never used: nothing here chats to the agent, so no provider is
        # reached. It is present because a provider that needs a key and does
        # not get one is a different failure, tested separately.
        "api_key" => "not-a-real-key",
        "working_copy" => root,
        "role" => "coding"
      },
      overrides
    )
  end

  describe "refusing before starting" do
    test "a request naming no agent is refused", %{root: root} do
      assert {:error, :agent_id_required} =
               Agents.launch(Map.delete(request(root), "agent_id"))
    end

    test "a checkout that is not there is named, not discovered mid-turn", %{root: root} do
      gone = Path.join(root, "no-such-copy")

      assert {:error, :working_copy_missing} =
               Agents.launch(request(root, %{"working_copy" => gone})),
             "a missing checkout has to be refused here. Found inside a tool call " <>
               "it arrives as a confusing message about a path instead of " <>
               "'this copy is gone'."
    end

    test "a provider this harness does not know is named", %{root: root} do
      assert {:error, :unknown_provider} =
               Agents.launch(request(root, %{"provider" => "cursor"}))
    end

    test "a credential missing the field its provider needs says which field", %{root: root} do
      assert {:error, :credential_missing_api_key} =
               Agents.launch(Map.delete(request(root), "api_key")),
             "naming the missing field is the difference between reconnecting a " <>
               "provider and hunting a config bug"
    end
  end

  describe "the lifecycle" do
    test "an agent starts, is listed, and stops", %{root: root} do
      req = request(root)
      id = req["agent_id"]

      assert {:ok, %{agent_id: ^id}} = Agents.launch(req)
      assert id in Agents.running()
      assert Engine.running?(id)

      assert :ok = Agents.halt(id)
      refute id in Agents.running()

      refute Engine.running?(id),
             "a stop that leaves the process running is the defect this whole " <>
               "story exists for — the row said stopped and the thing kept going"
    end

    test "stopping one agent leaves the others running", %{root: root} do
      a = request(root)
      b = request(root)

      {:ok, _} = Agents.launch(a)
      {:ok, _} = Agents.launch(b)

      :ok = Agents.halt(a["agent_id"])

      refute Engine.running?(a["agent_id"])

      assert Engine.running?(b["agent_id"]),
             "a stop that catches a sibling is indistinguishable from this one at " <>
               "the call site and is worse than having no stop at all"

      :ok = Agents.halt(b["agent_id"])
    end

    test "stopping an agent that is not running says so", %{root: _root} do
      assert {:error, :not_running} = Agents.halt("never-started")
    end
  end
end
