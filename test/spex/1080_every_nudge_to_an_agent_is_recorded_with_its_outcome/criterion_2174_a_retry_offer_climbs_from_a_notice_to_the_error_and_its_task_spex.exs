defmodule CodeMySpecSpex.Story1080.Criterion2174Spex do
  @moduledoc """
  Story 1080 — Every nudge to an agent is recorded with its outcome.
  Criterion 2174 — A retry offer climbs from a notice, to the error and its
  task.
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

  spex "A retry offer's rungs climb from a notice to the error and its task", criterion: 2174 do
    scenario "the retried turn is ignored once before the agent acts on it" do
      given_ "an agent whose turn failed", context do
        {:ok, Map.put(context, :agent, asked_and_started(context))}
      end

      when_ "its turn fails, and it ignores the first rung", context do
        :ok = report_turn_failed(context, context.agent, @failure)
        id = context.agent
        assert_receive {:agent_dispatch, ^id, _ref, first}, 2_000
        :ok = Fixtures.put_agent_mid_turn(context.scope, id)
        :ok = Fixtures.end_turn(context.scope, id)
        {:ok, Map.put(context, :first, first)}
      end

      then_ "the first rung says its last turn failed and to carry on", context do
        assert context.first =~ @failure, context.first
        refute context.first =~ "Make me a help page.", context.first
        {:ok, context}
      end

      then_ "the next rung gives the error and the task it was on", context do
        id = context.agent
        # Past any repeat of the first rung the mailbox delivers again.
        second = next_rung(id, "The request was:")
        assert second =~ @failure, second
        assert second =~ "Make me a help page.", second
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

  defp next_rung(id, needle, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:agent_dispatch, ^id, _ref, text} ->
        rung(String.contains?(text, needle), text, id, needle, deadline)
    after
      remaining -> flunk("no dispatch to #{id} carried #{inspect(needle)}")
    end
  end

  defp rung(true, text, _id, _needle, _deadline), do: text
  defp rung(false, _text, id, needle, deadline), do: next_rung(id, needle, deadline)
end
