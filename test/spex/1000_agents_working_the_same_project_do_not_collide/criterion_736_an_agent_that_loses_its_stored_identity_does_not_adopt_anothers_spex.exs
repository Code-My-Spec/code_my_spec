defmodule CodeMySpecSpex.Story1000.Criterion736Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 736 — An agent that loses its stored identity does not adopt another's.

  Rule: An agent's identity is issued by the server and survives a restart.

  The dangerous half of the previous criterion. Since a returning agent is
  recognised by the id it presents, the tempting shortcut for one that presents
  none is to match it on something else — its `root`, most obviously, which is
  right there in the join payload. That would be wrong in exactly the case story
  733 describes: two containers at `/workspace/app` are two agents, so matching on
  root would hand a fresh checkout somebody else's files.

  So a join with no id is always a new agent, even from a path the server has
  seen. Surface: the channel.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version 1
  @root "/workspace/forgetful"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A checkout with no id is a new agent" do
    scenario "An agent that loses its stored identity does not adopt another's" do
      given_ "an agent has registered and synced its files", context do
        {:ok, reply, socket} = join_as(context, nil)

        ref =
          Phoenix.ChannelTest.push(socket, "observations", %{
            "observations" => [observation("lib/original.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, _summary, 1000)

        {:ok, context |> Map.put(:original, socket) |> Map.put(:original_id, id_of(reply))}
      end

      when_ "its stored identity is lost and it registers again", context do
        # The gitignored id file is gone — a fresh clone, a wiped container, a
        # `git clean`. Everything else about the checkout is identical, including
        # the root, which is the whole trap.
        {:ok, reply, socket} = join_as(context, nil)

        {:ok, context |> Map.put(:reregistered, socket) |> Map.put(:new_reply, reply)}
      end

      then_ "the server issues a new identity", context do
        refute id_of(context.new_reply) == context.original_id,
               "a checkout presenting no id was recognised by its root and handed the " <>
                 "previous agent's identity. Two containers at one path are two agents " <>
                 "(criterion 733), so this hands a stranger somebody else's files."

        {:ok, context}
      end

      then_ "it syncs its own files rather than attaching to the previous agent's", context do
        ref =
          Phoenix.ChannelTest.push(context.reregistered, "observations", %{
            "observations" => [observation("lib/fresh.ex")]
          })

        Phoenix.ChannelTest.assert_reply(ref, :ok, summary, 1000)

        assert summary["observations"] == 1

        {:ok, context}
      end
    end
  end

  defp join_as(context, working_copy_id) do
    UserSocket
    |> socket("harness_forget_#{System.unique_integer([:positive])}", %{scope: context.scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
      "contract_version" => @contract_version,
      "harness_id" => working_copy_id,
      "root" => @root,
      "label" => "the harness at #{@root}"
    })
  end

  defp id_of(reply), do: reply["harness_id"] || reply[:working_copy_id]

  defp observation(path) do
    %{
      "path" => path,
      "role" => "implementation",
      "fingerprint" => "f",
      "mtime" => "2026-08-12T00:00:00.000000Z"
    }
  end
end
