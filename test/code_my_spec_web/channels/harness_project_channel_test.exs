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

  describe "hook decisions" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      %{channel: channel}
    end

    test "a stop decision comes back over the channel", %{channel: channel} do
      ref =
        push(channel, "hook_decision", %{
          "hook" => "stop",
          "payload" => %{"session_id" => "s1", "cwd" => "/workspace/app"}
        })

      assert_reply ref, :ok, decision, 5_000
      assert is_map(decision)
    end

    # The server cannot know which port the harness serves on, and the rewritten
    # analysis curl only means anything on the agent's own machine. Refusing is
    # the only honest answer; pointing it somewhere plausible would produce a
    # command that runs and reports against the wrong process.
    test "pre-tool-use without the harness's port is refused, not guessed",
         %{channel: channel} do
      ref =
        push(channel, "hook_decision", %{
          "hook" => "pre-tool-use",
          "payload" => %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}}
        })

      assert_reply ref, :error, %{"reason" => "port_required"}, 5_000
    end

    test "an unknown hook says so", %{channel: channel} do
      ref = push(channel, "hook_decision", %{"hook" => "not-a-hook", "payload" => %{}})

      assert_reply ref, :error, %{"reason" => "unknown_hook: not-a-hook"}, 5_000
    end
  end

  # This is the test that would have caught the defect it was written for.
  #
  # The harness pushed `hook_decision` for weeks of work while this server had no
  # clause for it. The old catch-all returned `{:noreply, socket}`, so the push
  # got no reply at all and the harness sat out its full timeout on every hook —
  # on the critical path of every agent turn. Both suites stayed green: this one
  # did not know the event existed, and the harness's tests run against a fake
  # server that did implement it.
  #
  # A fake is the right way to test the harness in isolation. What it cannot do
  # is notice that it has drifted from the real thing, so that has to be asserted
  # somewhere, and this is the somewhere.
  describe "the wire contract" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        scope |> connect() |> subscribe_and_join(HarnessProjectChannel, topic)

      %{channel: channel}
    end

    # Keep in step with the events CmsHarness pushes — see
    # `CmsHarness.Project.ChannelClient` and `CmsHarnessTest.FakeServer`.
    @harness_events ~w(read_model observations hook_decision)

    test "every event the harness sends is one this server implements", %{channel: channel} do
      for event <- @harness_events do
        ref = push(channel, event, %{"observations" => [], "hook" => "stop", "payload" => %{}})

        assert_receive %Phoenix.Socket.Reply{ref: ^ref, payload: payload}, 5_000, """
        The harness pushes #{inspect(event)} and this server never replied to it.

        A push with no reply is indistinguishable from a slow server: the harness
        waits out its whole decision timeout and then fails closed.
        """

        # Not merely "a reply came back" — the catch-all replies too, and a test
        # satisfied by that would pass for an event nobody implemented, which is
        # the exact hole it exists to close.
        refute payload["reason"] == "unknown_event", """
        #{inspect(event)} reached the catch-all: the harness sends it and this
        server has no clause for it. Add a handle_in clause, or stop sending it.
        """
      end
    end

    test "an event neither side knows is refused rather than swallowed",
         %{channel: channel} do
      ref = push(channel, "some_event_from_a_newer_harness", %{})

      assert_reply ref, :error, %{"reason" => "unknown_event"}, 5_000
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
