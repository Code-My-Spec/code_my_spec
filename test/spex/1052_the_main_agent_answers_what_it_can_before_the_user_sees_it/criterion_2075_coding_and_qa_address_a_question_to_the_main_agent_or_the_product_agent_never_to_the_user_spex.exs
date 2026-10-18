defmodule CodeMySpecSpex.Story1052.Criterion2075Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2075 — Coding and QA address a question to the main agent or
  the product agent, never to the user.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Coding and QA address a question to the main agent or the product agent, never to the user",
    criterion: 2075 do
    scenario "a QA agent asks a plain question while the main agent is not running" do
      given_ "a running product agent, no main agent, and a QA agent", context do
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        qa = Fixtures.running_agent(context.scope, role: "qa", continuous: true)

        {:ok,
         Map.merge(context, %{
           product_id: product.id,
           qa_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: qa.id}}
         })}
      end

      when_ "the QA agent asks a question naming neither `to` nor `about`", context do
        params = %{
          questions: [
            %{
              "question" => "Should this edge case fail loudly?",
              "options" => [%{"label" => "Yes"}]
            }
          ]
        }

        reply =
          ToolLibrary.run(
            "ask_user_question",
            params,
            Map.put(context.qa_frame.assigns, :scope, context.qa_frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))
        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it reaches the product agent, never the user", context do
        {:reply, listing, _frame} =
          ListNotifications.execute(
            %{},
            %Frame{assigns: %{current_scope: context.scope, agent_id: context.product_id}}
          )

        assert response_text(listing) =~ context.question_id,
               """
               A QA question with no addressee did not reach either answerer \
               while the main agent was down — it should have fallen to the \
               product agent rather than the user.

               #{response_text(listing)}
               """

        {:ok, view, _html} = live(context.conn, "/app/notifications")

        refute has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               The question reached the user directly even though the product \
               agent was still running to take it.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
