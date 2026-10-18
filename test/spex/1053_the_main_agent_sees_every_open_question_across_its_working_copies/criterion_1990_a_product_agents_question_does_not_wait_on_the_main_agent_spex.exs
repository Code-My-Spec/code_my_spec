defmodule CodeMySpecSpex.Story1053.Criterion1990Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question across its working
  copies.
  Criterion 1990 — A product agent's question does not wait on the main agent.

  Rule: a question the main agent has not yet dealt with is visibly waiting
  for it. A product agent's own question is the exception by construction
  (its `about: "criteria"` surface, story 1017): it is never the main agent's
  to settle, so it has to read as already waiting on the user, not as a fresh
  item competing for the main agent's attention.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A product agent's own question is never the main agent's to settle", criterion: 1990 do
    scenario "a product agent asks a question about a story's criteria" do
      given_ "a product agent with an open question", context do
        reply = join_working_copy(context, "/tmp/spex-1990", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        product = Fixtures.running_agent(scope, role: "product", working_copy: "/tmp/spex-1990")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: product.id}}

        asked =
          ToolLibrary.run(
            "ask_user_question",
            %{
              about: "criteria",
              questions: [
                %{
                  "question" => "Should criterion 42 cover the retry case too?",
                  "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
                }
              ]
            },
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, asked), response_text(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:product, product)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent looks at what is waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        inbox =
          ToolLibrary.run(
            "list_notifications",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, inbox), response_text(inbox)
        {:ok, Map.put(context, :listing, response_text(inbox))}
      end

      then_ "it is not shown as needing the main agent's attention", context do
        refute context.listing =~ ~r/needs your attention/i,
               """
               A product agent's own question is being offered to the main agent
               as something for it to settle, which it never is.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end

      then_ "it is shown as waiting on the user", context do
        assert context.listing =~ context.question_id and
                 context.listing =~ ~r/waiting on the user/i,
               """
               The product agent's question is missing from the listing, or is
               not shown as waiting on the user.

               listing:
               #{context.listing}
               """

        {:ok, context}
      end
    end
  end
end
