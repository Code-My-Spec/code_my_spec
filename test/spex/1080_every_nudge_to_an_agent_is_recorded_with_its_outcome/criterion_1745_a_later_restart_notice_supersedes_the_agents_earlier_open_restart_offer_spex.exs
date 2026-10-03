defmodule CodeMySpecSpex.Story1080.Criterion1745Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1745 — A later restart notice supersedes the agent's earlier open restart
  offer.

  A harness that comes back asks the server which agents to restore. Before
  answering, the server tells each one what became of its turn — and that
  notice is an offer like any other nudge (f5699eb9).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A second restart supersedes the first restart offer", criterion: 1745 do
    scenario "the harness restarts twice before the agent takes a turn" do
      given_ "an idle agent whose harness already came back once", context do
        context = a_harness(context)
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        context = Map.put(context, :agent, agent.id)
        :ok = restores(context)
        {:ok, context}
      end

      when_ "the harness comes back again", context do
        {:ok, Map.put(context, :restored, restores(context))}
      end

      then_ "the first restart offer is superseded and the second is open", context do
        # Newest first.
        assert [second, first] = offers(context, context.agent, %{kind: "resume"}),
               listing(context)

        assert first.status == "superseded"
        assert second.status == "open"
        {:ok, context}
      end
    end
  end

  # A harness on its own checkout, and the scope addressed to it.
  defp a_harness(context) do
    {reply, socket} =
      join_working_copy_socket(context, "/tmp/spex-#{System.unique_integer([:positive])}", "copy")

    Map.merge(context, %{
      socket: socket,
      scope: %{context.scope | active_working_copy_id: reply[:working_copy_id]}
    })
  end

  # What a harness that has just come back up asks first.
  defp restores(context) do
    ref = Phoenix.ChannelTest.push(context.socket, "agents_to_restore", %{})
    Phoenix.ChannelTest.assert_reply(ref, :ok, _agents, 5_000)
    :ok
  end
end
