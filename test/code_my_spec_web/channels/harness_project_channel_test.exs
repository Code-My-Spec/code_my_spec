defmodule CodeMySpecWeb.HarnessProjectChannelTest do
  @moduledoc """
  The claim this channel exists to make: **the channel is the lease**.

  Joining takes the project's advisory lock on a connection the channel owns,
  so leaving — or dying, or losing the network — frees it with no deadline to
  wait out. These drive the channel rather than the Leases API directly,
  because the property under test is about the channel's lifetime.
  """

  # Not async: advisory locks are per-database, so concurrent tests taking them
  # are genuinely sharing state even with sandboxed rows.
  use CodeMySpecTest.DataCase, async: false

  import Phoenix.ChannelTest
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  defp connect(scope) do
    UserSocket
    |> socket("harness_test", %{scope: scope})
    |> Map.update!(:assigns, &Map.put(&1, :harness_label, "the harness at /workspace/app"))
  end

  describe "joining" do
    test "a harness takes the project when it is free", %{scope: scope, topic: topic} do
      assert {:ok, _reply, _socket} =
               scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)
    end

    test "a second harness is refused and told who holds it", %{scope: scope, topic: topic} do
      {:ok, _reply, _first} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      assert {:error, %{reason: "project_in_use", held_by: held_by}} =
               scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      assert held_by == "the harness at /workspace/app",
             "a refusal has to name the checkout to go and stop"
    end

    test "a harness cannot join a project its scope does not cover", %{scope: scope} do
      other = full_scope_fixture()

      assert {:error, %{reason: "unauthorized"}} =
               scope
               |> connect()
               |> subscribe_and_join(
                 HarnessProjectChannel,
                 "harness_project:#{other.active_project_id}"
               )
    end

    test "an unknown topic shape is refused", %{scope: scope} do
      assert {:error, %{reason: "invalid topic"}} =
               scope |> connect() |> subscribe_and_join(HarnessProjectChannel, "nonsense:1")
    end
  end

  describe "read_model" do
    test "hands back everything a database-less harness needs to scan",
         %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      ref = push(channel, "read_model", %{})

      assert_reply ref, :ok, payload, 2_000

      # The Scanner's own moduledoc names these as the only things it needs
      # from the domain; everything else it derives from the working copy.
      assert Map.has_key?(payload, "component_by_module")
      assert Map.has_key?(payload, "component_by_id")
      assert is_list(payload["story_ids"]), "a MapSet has no JSON form — it must cross as a list"
      assert is_boolean(payload["strict"])
    end
  end

  describe "the channel's lifetime is the lease" do
    # The channel is linked to the test process, so its death would take the
    # test with it — and its death is the thing under test.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "leaving frees the project for the next harness", %{scope: scope, topic: topic} do
      {:ok, _reply, first} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      ref = Process.monitor(first.channel_pid)
      leave(first)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      assert eventually(fn ->
               match?(
                 {:ok, _, _},
                 scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)
               )
             end),
             "a departed harness must not keep holding the project"
    end

    test "a killed channel frees the project — no release, no expiry",
         %{scope: scope, topic: topic} do
      {:ok, _reply, first} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      # The case the design exists for: nothing gets to run on the way out, the
      # way it would if the container were killed or the network dropped.
      ref = Process.monitor(first.channel_pid)
      Process.exit(first.channel_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      assert eventually(fn ->
               match?(
                 {:ok, _, _},
                 scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)
               )
             end),
             "a killed harness must not hold a project until some deadline passes"
    end
  end

  # Postgres releases the lock as it reaps the closed connection — prompt, but
  # not synchronous with the channel process dying.
  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        Process.sleep(50)
        {:cont, false}
      end
    end)
  end
end
