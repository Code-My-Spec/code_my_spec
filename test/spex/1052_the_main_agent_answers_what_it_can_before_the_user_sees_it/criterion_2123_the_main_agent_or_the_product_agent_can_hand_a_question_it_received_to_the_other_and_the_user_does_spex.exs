defmodule CodeMySpecSpex.Story1052.Criterion2123Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2123 — The main agent or the product agent can hand a question
  it received to the other, and the user does not see it until one of them
  escalates it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListNotifications
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Main and product can hand a question to each other without the user seeing it",
       criterion: 2123 do
    scenario "main hands a question it cannot answer to product" do
      given_ "a coder's question is waiting on main, and a product agent is running", context do
        coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)

        coder_frame = %Frame{assigns: %{current_scope: context.scope, agent_id: coder.id}}

        params = %{
          questions: [
            %{"question" => "Does this behavior match what the story asked for?", "options" => []}
          ]
        }

        {:reply, reply, _frame} = AskUserQuestion.execute(params, coder_frame)
        refute reply.isError, response_text(reply)
        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))

        {:ok,
         Map.merge(context, %{
           question_id: question_id,
           main_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: main.id}},
           product_frame: %Frame{assigns: %{current_scope: context.scope, agent_id: product.id}}
         })}
      end

      when_ "main hands it sideways to product instead of answering it", context do
        {:reply, reply, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.question_id,
              to: "product",
              reason: "This is a product call, not a factual one."
            },
            context.main_frame
          )

        refute reply.isError, response_text(reply)
        {:ok, Map.put(context, :hand_reply, reply)}
      end

      then_ "it is product's to answer now", context do
        {:reply, listing, _frame} = ListNotifications.execute(%{}, context.product_frame)

        assert response_text(listing) =~ "Needs your attention" and
                 response_text(listing) =~ context.question_id,
               """
               The question handed from main did not show up as product's own \
               to answer.

               #{response_text(listing)}
               """

        {:ok, context}
      end

      then_ "and the user has not seen it", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        refute has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               A question handed sideways between main and product reached the \
               user, who should see it only once one of them escalates it.

               #{render(view)}
               """

        {:ok, context}
      end
    end
  end
end
