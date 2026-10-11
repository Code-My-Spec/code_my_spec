defmodule CodeMySpecSpex.Story1080.Criterion1744Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1744 — A harness restart that finds an agent mid-turn records its
  carry-on as an open resume offer on the restart, linked to it.

  A harness that comes back asks the server which agents to restore. An agent
  it caught mid-turn is sent a carry-on ahead of anything queued, and that
  carry-on is an offer like any other nudge (f5699eb9).
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

  spex "A mid-turn agent's carry-on is an open resume offer", criterion: 1744 do
    scenario "the harness comes back and its agent was part-way through a turn" do
      given_ "an agent on a harness's copy, mid-turn", context do
        context = a_harness(context)
        agent = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
        {:ok, Map.put(context, :agent, agent.id)}
      end

      when_ "the harness comes back and asks which agents to restore", context do
        {:ok, Map.put(context, :restored, restores(context))}
      end

      then_ "one open resume offer on the restart, linked to the carry-on",
            context do
        assert [offer] = offers(context, context.agent, %{kind: "resume"}), listing(context)
        assert {offer.subject, offer.status} == {"restart", "open"}
        assert [notice] = offer.messages
        assert notice =~ "Carry on from your last step"
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
