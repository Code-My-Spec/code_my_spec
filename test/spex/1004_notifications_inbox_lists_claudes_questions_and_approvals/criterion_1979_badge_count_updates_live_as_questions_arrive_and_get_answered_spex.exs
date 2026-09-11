defmodule CodeMySpecSpex.Story1004.Criterion1979Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1979 — Badge count updates live as questions arrive and get
  answered.

  The badge is what the user glances at while doing something else. A count
  that is only correct at page load makes the answer to "is anything waiting
  on me?" depend on when the tab was opened — and the whole reason for the
  badge is that they are not watching this page.

  Both directions, because they fail separately: a badge that counts up on
  arrival and never counts down keeps claiming work that is already done.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "The navbar count tracks what is pending without a reload" do
    scenario "Badge count updates live as questions arrive and get answered" do
      given_ "the user is on a page showing the navbar, with nothing pending", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification-badge'][data-count='0']"),
               "a count that starts wrong cannot be shown to update correctly"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "a question arrives while the page is open", context do
        id = Fixtures.ask_question(context.scope.user.id, title: "Arrived live")

        {:ok, Map.put(context, :question_id, id)}
      end

      then_ "the badge counts it without a reload", context do
        # The badge lives in a stateful `LiveComponent`, refreshed via
        # `send_update/2` from the badge's PubSub subscription rather than a
        # synchronous assign — a second message the view's mailbox processes
        # after the broadcast, so a single `has_element?/2` can win the race
        # and see the count from before it landed.
        eventually(fn ->
          assert has_element?(context.view, "[data-test='notification-badge'][data-count='1']"),
                 "a badge only correct at page load answers 'is anything waiting?' with " <>
                   "whenever the tab was opened"
        end)

        {:ok, context}
      end

      then_ "answering it counts back down", context do
        :ok = Fixtures.answer_question(context.question_id, %{"Which approach?" => "A"})

        eventually(fn ->
          assert has_element?(context.view, "[data-test='notification-badge'][data-count='0']"),
                 "a badge that only counts up keeps claiming work that is already done"
        end)

        {:ok, context}
      end
    end
  end
end
