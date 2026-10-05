defmodule CodeMySpecSpex.Story1052.Criterion1987Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 1987 — A product agent's question goes straight to the user.

  `RoleProfile.questions_to(:product)` already routes a product agent's own
  question to "user" rather than "main_agent" (criteria questions asked by
  someone else are the exception, routed to product by 8c91d5bc, and do not
  apply here — the asker here is product itself). What this criterion adds:
  `Agents.Main.question_raised/2` must not give the main agent a turn for a
  question it was never going to hold.
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

  spex "A product agent's question goes straight to the user", criterion: 1987 do
    scenario "a product agent asks whether a case its criteria leave open should be covered" do
      given_ "a running main agent and a running product agent", context do
        main = Fixtures.running_agent(context.scope, role: "main", continuous: true)
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)

        {:ok, Map.merge(context, %{main_id: main.id, product_id: product.id})}
      end

      when_ "the product agent asks whether a case its criteria leave open should be covered",
            context do
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
               The product agent's own question never reached the user's own inbox.

               #{render(view)}
               """

        {:ok, context}
      end

      then_ "the main agent is given no turn for it", context do
        offers = OfferHelpers.offers(context, context.main_id)

        assert offers == [],
               """
               The main agent was offered a turn for a question it was never going to
               hold — a question with holder "user" is not main's to act on, so nothing
               about it should have woken main.

               #{inspect(offers)}
               """

        {:ok, context}
      end
    end
  end
end
