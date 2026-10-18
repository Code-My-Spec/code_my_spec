defmodule CodeMySpecSpex.Story1052.Criterion2025Spex do
  @moduledoc """
  Story 1052 — The main agent answers what it can before the user sees it.
  Criterion 2025 — A product agent looks up an earlier answer itself instead
  of asking again.

  `MainAgent.search_answers/2` already finds a decision the user made before,
  by the same matching rule as `AnswerNotification`'s `basis: precedent`
  check — but `RoleProfile`'s `@product_tools` does not list
  `search_answers`, so product cannot reach it yet to look before asking
  the user something already settled.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A product agent looks up an earlier answer itself instead of asking again",
    criterion: 2025 do
    scenario "the user already decided whether refunds older than ninety days are covered" do
      given_ "the user has already answered a question about this exact case", context do
        question_id =
          Fixtures.ask_question(context.scope.user.id,
            questions: [
              %{
                "question" => "Should refunds older than ninety days be covered?",
                "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
              }
            ]
          )

        :ok = Fixtures.answer_question(context.scope, question_id, "Yes")

        {:ok, Map.put(context, :precedent_question_id, question_id)}
      end

      given_ "a running product agent", context do
        product = Fixtures.running_agent(context.scope, role: "product", continuous: true)
        {:ok, Map.put(context, :product_id, product.id)}
      end

      when_ "the product agent looks for a precedent before asking the same thing again",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.product_id}}

        reply =
          ToolLibrary.run(
            "search_answers",
            %{query: "refunds older than ninety days"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :search_reply, reply)}
      end

      then_ "it has the tool to look, not only main", context do
        assert "search_answers" in RoleProfile.tools(:product),
               """
               Product cannot reach `search_answers` yet — it is not in
               RoleProfile's @product_tools, so a product agent has no way to
               look before asking the user something already settled.
               """

        {:ok, context}
      end

      then_ "it finds the user's earlier decision rather than coming up empty", context do
        assert match?({:ok, _}, context.search_reply),
               "the search itself was refused:\n" <> response_text(context.search_reply)

        text = response_text(context.search_reply)

        assert text =~ context.precedent_question_id,
               """
               The precedent's own id was not in the result — the product agent
               has nothing to pass `answer_question` as `precedent_id`.

               #{text}
               """

        assert text =~ ~r/yes/i,
               """
               The earlier decision itself did not come back with the match.

               #{text}
               """

        {:ok, context}
      end
    end
  end
end
