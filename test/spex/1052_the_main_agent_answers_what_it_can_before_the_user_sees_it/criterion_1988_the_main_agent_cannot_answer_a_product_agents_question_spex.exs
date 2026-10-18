defmodule CodeMySpecSpex.Story1052.Criterion1988Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 1988 — The main agent cannot answer a product agent's question.

  The counterpart to 1987: a question routed past the main agent stays past
  it. `Agents.Main.within_scope/2` only checks a borrowed role's own tools
  today, never the question's own holder, so nothing yet stops the main
  agent from answering a question that was never routed to it.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent cannot answer a question that is the user's", criterion: 1988 do
    scenario "a product agent's question is waiting on the user" do
      given_ "a product agent's question is waiting on the user", context do
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)

        params = %{
          questions: [
            %{
              "question" => "Should refunds older than ninety days be covered by this story?",
              "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
            }
          ]
        }

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply),
               "the premise is a question waiting on the user, and raising it was refused:\n" <>
                 response_text(reply)

        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))

        {:ok, Map.put(context, :question_id, question_id)}
      end

      when_ "the main agent tries to answer it", context do
        {:reply, reply, _frame} =
          AnswerNotification.execute(
            %{notification_id: context.question_id, answer: "Yes", basis: "record"},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        {:ok, Map.put(context, :answer_reply, reply)}
      end

      then_ "it is refused and told the question is the user's", context do
        assert context.answer_reply.isError,
               "the main agent answered a question that was never routed to it:\n" <>
                 response_text(context.answer_reply)

        assert response_text(context.answer_reply) =~ ~r/user/i,
               """
               The refusal did not say the question belongs to the user.

               #{response_text(context.answer_reply)}
               """

        {:ok, context}
      end

      then_ "the question stays with the user, unanswered", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               The question is no longer waiting in the user's own inbox.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
