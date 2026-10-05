defmodule CodeMySpecSpex.Story1052.Criterion2024Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2024 — The main agent answers a product agent's record lookup itself.

  The counterpart to criterion 2023: not every product question is a
  judgment call main lacks the basis for. A record lookup — something the
  project already records, like which ready story carries no epic — is
  exactly the kind of question main answers for every other role today
  (criterion 1198). `Agents.Main.routed/3` currently sends every product
  question straight to "user" unconditionally (criterion 1987/2023's own
  routing), with no exception for one main could settle from the project's
  own records — so this is expected to fail until that routing adds one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerNotification
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.OfferHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent answers a product agent's record lookup itself", criterion: 2024 do
    scenario "a product agent asks which ready story on the project carries no epic" do
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

      when_ "the product agent asks which ready story on the project carries no epic",
            context do
        params = %{
          questions: [
            %{
              "question" => "Which ready story on this project has no epic assigned?",
              "options" => [%{"label" => "None do"}]
            }
          ],
          about: "record"
        }

        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.product_id}}
        {:reply, reply, _frame} = AskUserQuestion.execute(params, frame)

        refute reply.isError,
               "the premise is a question that was raised, and this one was refused:\n" <>
                 response_text(reply)

        [_, question_id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, response_text(reply))

        {:ok, Map.put(context, :question_id, question_id)}
      end

      then_ "the main agent is given a turn for it, not the user", context do
        offers = OfferHelpers.offers(context, context.main_id)

        refute offers == context.offers_before,
               """
               A record the project already holds is exactly the kind of question main
               answers for every other role — raising it should have woken main the
               same way, not skipped straight past it to the user.

               before: #{inspect(context.offers_before)}
               after:  #{inspect(offers)}
               """

        {:ok, context}
      end

      when_ "the main agent answers it from the project's own records", context do
        {:reply, reply, _frame} =
          AnswerNotification.execute(
            %{
              notification_id: context.question_id,
              answer: "None — every ready story on this project already has an epic.",
              basis: "record"
            },
            %Frame{assigns: %{current_scope: context.scope}}
          )

        {:ok, Map.put(context, :answer_reply, reply)}
      end

      then_ "the answer is accepted, not refused as the user's to give", context do
        refute context.answer_reply.isError,
               "main was refused a record lookup it had every basis to answer:\n" <>
                 response_text(context.answer_reply)

        {:ok, context}
      end
    end
  end
end
