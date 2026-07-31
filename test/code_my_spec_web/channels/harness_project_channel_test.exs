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

  describe "observations" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      %{channel: channel}
    end

    test "a manifest becomes File rows", %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo/accounts.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 120,
              "fingerprint" => "abc123",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, %{"upserted" => 1}, 2_000

      assert [%{path: "lib/todo/accounts.ex", role: :implementation}] =
               CodeMySpec.Files.list_files(scope)
    end

    # The manifest is the whole truth, so a path's absence is a deletion. This
    # is the reason it's sent whole rather than as a delta.
    test "a path missing from the next manifest is removed", %{channel: channel, scope: scope} do
      observation = fn path ->
        %{
          "path" => path,
          "role" => "implementation",
          "mtime" => "2026-07-28T10:00:00.000000Z",
          "size" => 10,
          "fingerprint" => "f-" <> path,
          "valid" => true,
          "validation_errors" => %{}
        }
      end

      ref =
        push(channel, "observations", %{
          "observations" => [observation.("a.ex"), observation.("b.ex")]
        })

      assert_reply ref, :ok, %{"upserted" => 2}, 2_000

      ref = push(channel, "observations", %{"observations" => [observation.("a.ex")]})
      assert_reply ref, :ok, %{"removed" => 1}, 2_000

      assert ["a.ex"] = scope |> CodeMySpec.Files.list_files() |> Enum.map(& &1.path)
    end

    # The defect class this whole design exists to avoid: a harness that failed
    # to scan must not be able to report the same thing as an empty project.
    test "an empty manifest is refused rather than obeyed", %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, _, 2_000

      ref = push(channel, "observations", %{"observations" => []})
      assert_reply ref, :error, %{"reason" => "empty_manifest"}, 2_000

      assert length(CodeMySpec.Files.list_files(scope)) == 1,
             "an empty manifest must not be able to wipe a project's files"
    end

    test "a role this server does not know is reported as skew, not written as nil",
         %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "some_role_from_a_newer_harness",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :error, %{"reason" => "invalid_manifest", "problems" => problems}, 2_000
      assert Enum.any?(problems, &String.contains?(&1, "some_role_from_a_newer_harness"))

      assert CodeMySpec.Files.list_files(scope) == [],
             "a manifest the server cannot understand must not be half-applied"
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
