defmodule CodeMySpecSpex.Story1000.Criterion743Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 743 — A sprite recreated on its own volume resumes as the same agent.

  Rule: One agent serves a working copy at a time.

  Criterion 735 is the same claim for a process restart; this is the claim for a
  container that no longer exists. Nothing of the sprite survives except the
  volume, and the id lives on the volume — so "the same agent" has to mean "the
  id the volume carries", not anything about the machine.

  That matters here more than for a local restart, because a sprite's hostname is
  generated: it is different on every recreation, so any identity derived from the
  host would make each recreation a new agent, orphaning its files every time.

  Surface: the channel. A sprite authenticates with a deploy key rather than a
  user session, which `UserSocket.connect/2` records as `:deploy_key_project_id`
  — assigned here because assigning what production does not is how a channel
  test passes while every real refusal says "an unknown host".
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @volume "/workspace/app"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A sprite is its volume, not its container" do
    scenario "A sprite recreated on its own volume resumes as the same agent" do
      given_ "a sprite has registered as an agent and synced its files", context do
        {:ok, reply, socket} = join_as(context, nil, "sprite-abc123")

        ref =
          Phoenix.ChannelTest.push(socket, "observations", %{
            "observations" => [observation("lib/on_the_volume.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary)

        {:ok, context |> Map.put(:socket, socket) |> Map.put(:volume_id, id_of(reply))}
      end

      when_ "its container is destroyed and recreated on the same volume", context do
        :ok = destroy_container(context.socket)

        # A new container: different generated hostname, same volume, so the same
        # id comes back off the disk.
        {:ok, reply, socket} = join_as(context, context.volume_id, "sprite-xyz789")

        {:ok, context |> Map.put(:recreated, socket) |> Map.put(:recreated_reply, reply)}
      end

      then_ "it presents the identity stored on that volume", context do
        assert id_of(context.recreated_reply) == context.volume_id,
               "the recreated sprite was issued a different id though it presented the one on " <>
                 "its volume. A sprite's hostname is generated, so if identity moves with the " <>
                 "container every recreation orphans the volume's files. Got: " <>
                 inspect(context.recreated_reply)

        {:ok, context}
      end

      then_ "it resumes against its existing files rather than registering a second agent",
            context do
        ref =
          Phoenix.ChannelTest.push(context.recreated, "observations", %{
            "observations" => [observation("lib/on_the_volume.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, summary)

        assert summary["observations"] == 1

        {:ok, context}
      end
    end
  end

  defp join_as(context, harness_id, hostname) do
    UserSocket
    |> socket("sprite_#{hostname}", %{
      scope: context.scope,
      deploy_key_project_id: context.project.id
    })
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
      "contract_version" => @contract_version,
      "harness_id" => harness_id,
      "root" => @volume,
      "label" => "the harness at #{@volume} on #{hostname}"
    })
  end

  # The container going away, from the server's side: the connection drops and
  # the lease it held is free. Unlinked first because the test process is linked
  # to the channel and would otherwise exit with it.
  defp destroy_container(socket) do
    pid = socket.channel_pid
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Phoenix.ChannelTest.leave(socket)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    :ok
  end

  defp id_of(reply), do: reply["harness_id"] || reply[:harness_id]

  defp observation(path) do
    %{
      "path" => path,
      "role" => "implementation",
      "fingerprint" => "vol",
      "mtime" => "2026-08-12T00:00:00.000000Z"
    }
  end
end
