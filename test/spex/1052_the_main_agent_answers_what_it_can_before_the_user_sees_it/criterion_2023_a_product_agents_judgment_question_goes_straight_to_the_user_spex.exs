defmodule CodeMySpecSpex.Story1052.Criterion2023Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2023 — A product agent's judgment question goes straight to the user.

  Replaces retired criterion 1987, narrowed: only a *judgment* question from
  product — one main has no basis to settle, because main does not design
  the epic — skips main entirely. A record lookup is criterion 2024's case,
  not this one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.OfferHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A product agent's judgment question goes straight to the user", criterion: 2023 do
    scenario "a product agent asks whether a case its criteria leave open should be covered" do
      given_ "a running main agent and a running product agent", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)

        {:ok,
         Map.merge(context, %{
           main_id: main.id,
           product_id: product.id,
           offers_before: OfferHelpers.offers(context, main.id)
         })}
      end

      when_ "the product agent asks a question no project record answers", context do
        params = %{
          questions: [
            %{
              "question" => "Should refunds older than ninety days be covered by this story?",
              "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
            }
          ]
        }

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.product_id}}
        {:reply, reply, _frame} = AskUserQuestion.execute(params, frame)

        refute reply.isError,
               "the premise is a question that was raised, and this one was refused:\n" <>
                 response_text(reply)

        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))

        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "it reaches the user", context do
        {:ok, view, _html} = live(context.conn, "/app/notifications")

        assert has_element?(view, "[data-test='notification'][data-id='#{context.question_id}']"),
               """
               The product agent's own judgment question never reached the user's own inbox.

               #{render(view)}
               """

        {:ok, context}
      end

      then_ "the main agent is given no turn for it", context do
        offers = OfferHelpers.offers(context, context.main_id)

        assert offers == context.offers_before,
               """
               The product agent's judgment question added a new turn offer for main —
               a question with no basis main holds is not main's to act on, so nothing
               about raising it should have woken main.

               before: #{inspect(context.offers_before)}
               after:  #{inspect(offers)}
               """

        {:ok, context}
      end
    end
  end
end
