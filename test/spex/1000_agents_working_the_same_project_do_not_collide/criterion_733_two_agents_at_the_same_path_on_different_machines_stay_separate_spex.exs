defmodule CodeMySpecSpex.Story1000.Criterion733Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 733 — Two agents at the same path on different machines stay separate.

  Rule: An agent's files, problems and components belong to that agent alone.

  This is the case that decided the whole story. Every client-derived identity
  fails here: a checkout path collides when two containers both sit at
  `/workspace/app`, host+path collides for exactly the containers whose hostnames
  are generated, and a session id churns. So the server issues the id and the
  client only presents it.

  Surface: the channel. Identity is issued at join, so two joins reporting the
  same `root` from different machines is precisely the experiment.

  Note what this does *not* do: it never asserts that `root` differs, because the
  premise is that it doesn't. `root` is data the harness reports about itself,
  never identity — two containers at `/workspace/app` report the same string and
  must remain two agents.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  alias CodeMySpecWeb.{HarnessProjectChannel, UserSocket}
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @contract_version CodeMySpecWeb.HarnessProjectChannel.contract_version()
  @shared_path "/workspace/app"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The same path on two machines is two agents" do
    scenario "Two agents at the same path on different machines stay separate" do
      given_ "two agents are serving the same project from different machines", context do
        # Neither presents an id: each is a fresh checkout announcing itself. The
        # label is what a harness reports for its host, and it is the only thing
        # distinguishing these two joins.
        {:ok, first_reply, first} = join_as(context, "box-one")
        {:ok, second_reply, second} = join_as(context, "box-two")

        {:ok,
         context
         |> Map.put(:first, first)
         |> Map.put(:second, second)
         |> Map.put(:first_id, id_of(first_reply))
         |> Map.put(:second_id, id_of(second_reply))}
      end

      when_ "each syncs its files", context do
        first_ref =
          Phoenix.ChannelTest.push(context.first, "observations", %{
            "observations" => [observation("lib/only_on_box_one.ex", "one")]
          })

        second_ref =
          Phoenix.ChannelTest.push(context.second, "observations", %{
            "observations" => [observation("lib/only_on_box_two.ex", "two")]
          })

        {:ok, context |> Map.put(:first_ref, first_ref) |> Map.put(:second_ref, second_ref)}
      end

      then_ "neither agent's rows are overwritten by the other", context do
        assert context.first_id != context.second_id,
               "both machines were issued the same identity, so they will write the same " <>
                 "rows — which is the collision this story exists to prevent. Both reported " <>
                 "root #{@shared_path}, which is data about a checkout and not identity."

        {:ok, context}
      end

      then_ "each stop hook reports only its own machine's state", context do
        # A second, like the other channel criteria in the suite. The default
        # `assert_reply` window is 100ms, which is a wait rather than a claim:
        # this step is about *what* each hook reports, not how quickly, and a
        # stop hook that answers in 150ms has not collided with anything. The
        # analyzer caught this red on a cold run and it passed 31 consecutive
        # repeats afterwards, which is what a too-short wait looks like from
        # the outside.
        Phoenix.ChannelTest.assert_reply(context.first_ref, :ok, first_summary, 1000)
        Phoenix.ChannelTest.assert_reply(context.second_ref, :ok, second_summary, 1000)

        # Each manifest is accepted on its own terms. A server that treated these
        # as one working copy would take the second as a full replacement of the
        # first, and the count is where that shows.
        assert first_summary["observations"] == 1
        assert second_summary["observations"] == 1

        {:ok, context}
      end
    end
  end

  defp join_as(context, host) do
    UserSocket
    |> socket("harness_#{host}", %{scope: context.scope})
    |> subscribe_and_join(HarnessProjectChannel, "harness_project:#{context.project.id}", %{
      "contract_version" => @contract_version,
      "harness_id" => nil,
      "root" => @shared_path,
      "label" => "the harness at #{@shared_path} on #{host}",
      "device" => %{"id" => Fixtures.device_fixture(context.scope).id}
    })
  end

  defp id_of(reply), do: reply["harness_id"] || reply[:working_copy_id]

  defp observation(path, fingerprint) do
    %{
      "path" => path,
      "role" => "implementation",
      "fingerprint" => fingerprint,
      "mtime" => "2026-08-12T00:00:00.000000Z"
    }
  end
end
