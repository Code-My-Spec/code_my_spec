defmodule CodeMySpecSpex.Story1004.Criterion1978Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1978 — Pending items sort above answered history.

  Everything in this inbox is something an agent is blocked on until the user
  acts. Newest-first would be the ordinary answer and is the wrong one here:
  a run of answered questions from an hour ago would sit above the one thing
  still waiting.

  History is kept rather than dropped — it is how the user checks what they
  already told the agent — but it goes below.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "What is still waiting is surfaced ahead of what is finished" do
    scenario "Pending items sort above answered history" do
      given_ "an older question that has already been answered", context do
        answered = Fixtures.ask_question(context.scope.user.id, title: "Already answered")
        :ok = Fixtures.answer_question(answered, %{"Which approach?" => "A"})

        {:ok, Map.put(context, :answered_id, answered)}
      end

      when_ "a newer question arrives and is still waiting", context do
        pending = Fixtures.ask_question(context.scope.user.id, title: "Still waiting")

        {:ok, Map.put(context, :pending_id, pending)}
      end

      then_ "the pending one is listed above the answered one", context do
        {:ok, view, html} = live(context.conn, "/app/notifications")

        ids =
          Regex.scan(~r/data-test="notification" data-id="([^"]+)"/, html)
          |> Enum.map(fn [_, id] -> id end)

        assert Enum.find_index(ids, &(&1 == context.pending_id)) <
                 Enum.find_index(ids, &(&1 == context.answered_id)),
               "the one thing an agent is still blocked on cannot sit under finished history"

        {:ok, Map.put(context, :view, view)}
      end

      then_ "each item shows its own status", context do
        assert has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.pending_id}'][data-status='pending']"
               ),
               "position alone does not say which items still need the user"

        assert has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.answered_id}'][data-status='answered']"
               ),
               "an answered item that does not say so reads as one more thing to do"

        {:ok, context}
      end
    end
  end
end
