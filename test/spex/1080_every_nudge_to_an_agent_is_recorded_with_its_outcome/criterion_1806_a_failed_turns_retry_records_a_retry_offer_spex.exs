defmodule CodeMySpecSpex.Story1080.Criterion1806Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1806 — A failed turn's retry records a retry offer.

  A turn that fails is said back to the agent once, with the request it failed
  on.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.OfferHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @failure "Claude Code returned tool_use without any tool calls"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup context do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok = Fixtures.install_recording_agent_transport(context)
    :ok
  end

  spex "A failed turn's retry is recorded as an offer", criterion: 1806 do
    scenario "a turn fails on something I asked" do
      given_ "I asked an agent for something and it started on it", context do
        {:ok, Map.put(context, :agent, asked_and_started(context))}
      end

      when_ "its turn fails", context do
        :ok = report_turn_failed(context, context.agent, @failure)
        {:ok, Map.put(context, :notice, retry_notice(context))}
      end

      # The request comes back on the retry ladder's next rung (criterion 2174).
      then_ "it is told about the failure", context do
        assert context.notice =~ @failure
        {:ok, context}
      end

      then_ "one retry offer is recorded, linked to that notice", context do
        assert [offer] = offers(context, context.agent, %{kind: "retry"}),
               "expected one retry offer:\n" <> listing(context)

        assert offer.subject == "failed_turn"
        assert offer.messages == [excerpt(context.notice)]
        {:ok, context}
      end
    end
  end

  defp asked_and_started(context) do
    agent = Fixtures.running_agent(context.scope, role: "coding")
    {:ok, live, _} = live(context.conn, Fixtures.agent_conversation_path(context.scope, agent))

    live
    |> form("[data-test='agent-message-form']", message: "Make me a help page.")
    |> render_submit()

    id = agent.id
    assert_receive {:agent_dispatch, ^id, _ref, "Make me a help page."}, 2_000
    :ok = Fixtures.put_agent_mid_turn(context.scope, agent.id)
    agent.id
  end

  defp retry_notice(context) do
    id = context.agent
    assert_receive {:agent_dispatch, ^id, _ref, notice}, 2_000
    notice
  end
end
