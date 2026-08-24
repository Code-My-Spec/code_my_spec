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

  describe "where an agent's steps are reported" do
    test "only to the copy the agent runs in", %{root: root} do
      # Two checkouts on one harness, which is the ordinary case — worktrees of
      # one project usually are. Both have a channel; only one has the agent.
      sibling = Path.join(root, "sibling")
      File.mkdir_p!(sibling)

      mine = fake_channel(root)
      theirs = fake_channel(sibling)

      # A base URL nothing listens on, so the turn fails at once and no request
      # leaves this machine. The step being asserted on is announced before any
      # provider is reached: handing an agent a message is itself a thing that
      # happened, and it is reported the moment the agent takes it.
      agent = request(root, %{"base_url" => "http://127.0.0.1:1"})
      {:ok, _} = Agents.launch(agent)

      {:ok, _} = Agents.send_message(agent["agent_id"], "a-ref", "do something")

      assert_receive {:reported, ^mine, agent_id}, 1_000
      assert agent_id == agent["agent_id"]

      refute_receive {:reported, ^theirs, _}, 200

      :ok = Agents.halt(agent["agent_id"])
    end
  end

  # A stand-in for `CmsHarness.Project.ChannelClient`, registered where the real
  # one registers. `report_turn_event/3` looks a channel up by root and casts to
  # it, so anything registered under that key is a channel as far as it knows.
  #
  # Registered as a *project* too, which is what makes this a check rather than
  # a description. The reporter used to loop over `Projects.list/0` — every
  # checkout the harness serves — and against that version both of these
  # receive the step, which is the production symptom: one line per sibling
  # worktree in a transcript.
  defp fake_channel(root) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
        {:ok, _} = Registry.register(CmsHarness.Registry, {:project, root}, nil)

        receive do
          {:"$gen_cast", {:turn_event, agent_id, _envelope}} ->
            send(test, {:reported, self(), agent_id})
        after
          5_000 -> :ok
        end
      end)

    # Registration happens inside the process, so a report sent before it lands
    # finds nothing and the test fails for a reason that is not the claim.
    wait_for_registration(root)
    pid
  end

  defp wait_for_registration(root, attempts \\ 100)

  defp wait_for_registration(root, 0) do
    flunk("no channel ever registered for #{root}")
  end

  defp wait_for_registration(root, attempts) do
    case Registry.lookup(CmsHarness.Registry, {:channel, root}) do
      [] ->
        Process.sleep(5)
        wait_for_registration(root, attempts - 1)

      [_] ->
        :ok
    end
  end
end
