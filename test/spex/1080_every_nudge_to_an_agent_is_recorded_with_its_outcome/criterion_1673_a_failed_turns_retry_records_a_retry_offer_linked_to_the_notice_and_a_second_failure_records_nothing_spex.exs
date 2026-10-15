defmodule CodeMySpecSpex.Story1080.Criterion1673Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 1673 — A failed turn's retry records a retry offer linked to the
  notice, and a second failure records nothing.

  A turn that fails is said back to the agent once, with the request it failed
  on. A failure on that retry is left alone, so it is not offered again.
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

  spex "A failed turn's retry is recorded as an offer", criterion: 1673 do
    scenario "a turn fails on something I asked" do
      given_ "I asked an agent for something and it started on it", context do
        {:ok, Map.put(context, :agent, asked_and_started(context))}
      end

      when_ "its turn fails", context do
        :ok = report_turn_failed(context, context.agent, @failure)
        {:ok, Map.put(context, :notice, retry_notice(context))}
      end

      then_ "it is told about the failure, with my request", context do
        assert context.notice =~ @failure
        assert context.notice =~ "Make me a help page."
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

  spex "A failure on the retry records no second offer", criterion: 1673 do
    scenario "the retry fails too" do
      given_ "an agent whose turn failed and was told so", context do
        context = Map.put(context, :agent, asked_and_started(context))
        :ok = report_turn_failed(context, context.agent, @failure)
        _notice = retry_notice(context)
        :ok = Fixtures.drain_background_work()
        :ok = Fixtures.put_agent_mid_turn(context.scope, context.agent)
        flush_retry_dispatches(context.agent)
        {:ok, context}
      end

      when_ "the retry fails as well", context do
        :ok = report_turn_failed(context, context.agent, @failure)
        {:ok, context}
      end

      then_ "nothing more is sent, and the one retry offer is all there is", context do
        id = context.agent
        refute_receive {:agent_dispatch, ^id, _ref, _message}, 500

        assert [_one] = offers(context, context.agent, %{kind: "retry"}),
               "a second failure recorded another retry offer:\n" <> listing(context)

        {:ok, context}
      end
    end
  end

  # A retried wire acknowledgement has the same durable identity and is not
  # another offer or execution. Discard wire copies after consuming the retry.
  defp flush_retry_dispatches(agent_id) do
    receive do
      {:agent_dispatch, ^agent_id, _ref, _message} -> flush_retry_dispatches(agent_id)
    after
      0 -> :ok
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
