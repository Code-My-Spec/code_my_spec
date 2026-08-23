defmodule CodeMySpecSpex.Story1000.Criterion735Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 735 — A restarted agent resumes its own state.

  Rule: An agent's identity is issued by the server and survives a restart.

  Surface: the channel. The harness writes its issued id into a gitignored file
  in the working copy and presents it on every join after, so a restart is a
  second join carrying the same id. The client's storage is the premise; what
  must be true is what the *server* does with an id it has seen before — echo it,
  and attach the existing files rather than starting a second set.

  Leaving the channel is the restart: the lease is held by the connection, so
  dropping it is exactly what stopping the process does.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @root "/workspace/restarted"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent's identity outlives its process" do
    scenario "A restarted agent resumes its own state" do
      given_ "an agent has registered and synced its files", context do
        {:ok, reply, socket} = join_as(context, nil)
        issued = id_of(reply)

        ref =
          Phoenix.ChannelTest.push(socket, "observations", %{
            "observations" => [observation("lib/before_restart.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok, context |> Map.put(:socket, socket) |> Map.put(:issued_id, issued)}
      end

      when_ "the agent process is stopped and started again", context do
        # Leaving drops the connection holding the lease, which is what stopping
        # the process does. Re-joining presents the id the harness stored.
        :ok = stop_agent(context.socket)

        {:ok, reply, socket} = join_as(context, context.issued_id)

        {:ok, context |> Map.put(:rejoined, socket) |> Map.put(:rejoin_reply, reply)}
      end

      then_ "it presents the same identity", context do
        assert id_of(context.rejoin_reply) == context.issued_id,
               "the server issued a different id to a checkout presenting one it had already " <>
                 "been given, so a restart orphans everything the agent had. Got: " <>
                 inspect(context.rejoin_reply)

        {:ok, context}
      end

      then_ "it resumes against its existing files rather than creating a second set", context do
        # Re-syncing the same manifest converges rather than duplicating. A
        # second set would show as this file arriving as new work on a checkout
        # that already reported it.
        ref =
          Phoenix.ChannelTest.push(context.rejoined, "observations", %{
            "observations" => [observation("lib/before_restart.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, summary, 1000)

        assert summary["observations"] == 1

        {:ok, context}
      end
    end
  end

  defp join_as(context, working_copy_id) do
    UserSocket
    |> socket("harness_restart_#{System.unique_integer([:positive])}", %{scope: context.scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
      "contract_version" => @contract_version,
      "harness_id" => working_copy_id,
      "root" => @root,
      "label" => "the harness at #{@root}"
    })
  end

  # The test process is linked to the channel, so a bare `leave/1` takes the test
  # down with it (`EXIT … shutdown: :left`). Unlink first, then wait for the
  # process to actually be gone: the lease is held by the connection, and
  # re-joining before it is down races the refusal path that criterion 744 covers.
  defp stop_agent(socket) do
    pid = socket.channel_pid
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    :ok
  end

  defp id_of(reply), do: reply["harness_id"] || reply[:working_copy_id]

  defp observation(path) do
    %{
      "path" => path,
      "role" => "implementation",
      "fingerprint" => "same",
      "mtime" => "2026-08-12T00:00:00.000000Z"
    }
  end
end
