defmodule CodeMySpecSpex.Story1004.Criterion1981Spex do
  @moduledoc """
  Story 1004 — Notifications inbox lists Claude's questions and approvals.
  Criterion 1981 — Another user's requests are not visible.

  A question carries what an agent is doing and often what it found: file
  paths, commands, the shape of the work. A permission request carries the
  command verbatim. Neither belongs to anyone but the user whose agent asked.

  Worse than the leak: the inbox is answerable. A visible request from
  somebody else's agent is one another user can answer, and the agent would
  act on it.

  Both kinds are checked because they list through separate branches, and one
  can be scoped while the other is not.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "The inbox is scoped to its own user" do
    scenario "Another user's requests are not visible" do
      given_ "another user's agent has a question and a permission request waiting",
             context do
        other = Fixtures.user_fixture()

        question = Fixtures.ask_question(other.id, title: "Somebody else's question")
        permission = Fixtures.request_permission(other.id, tool_name: "Bash")

        {:ok,
         context
         |> Map.put(:other_question_id, question)
         |> Map.put(:other_permission_id, permission)}
      end

      when_ "this user opens their notifications inbox", context do
        mine = Fixtures.ask_question(context.scope.user.id, title: "My own question")

        {:ok, view, _html} = live(context.conn, "/app/notifications")

        {:ok, context |> Map.put(:view, view) |> Map.put(:my_question_id, mine)}
      end

      then_ "their own request is listed", context do
        assert has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.my_question_id}']"
               ),
               "an inbox that hides everything is scoped but useless — this is the control"

        {:ok, context}
      end

      then_ "the other user's question is not", context do
        refute has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.other_question_id}']"
               ),
               "a question carries what an agent is doing, and can be answered by whoever " <>
                 "sees it"

        {:ok, context}
      end

      then_ "the other user's permission request is not", context do
        refute has_element?(
                 context.view,
                 "[data-test='notification'][data-id='#{context.other_permission_id}']"
               ),
               "permission requests list through a separate branch and can be unscoped " <>
                 "while questions are scoped"

        {:ok, context}
      end
    end
  end
end
