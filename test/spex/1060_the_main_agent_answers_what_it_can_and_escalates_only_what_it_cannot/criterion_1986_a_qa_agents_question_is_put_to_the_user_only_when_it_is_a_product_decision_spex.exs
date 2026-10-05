defmodule CodeMySpecSpex.Story1060.Criterion1986Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 1986 — A QA agent's question is put to the user only when it is a
  product decision.

  Rule: a question that needs a product decision goes to the user. 1222
  established this for a coding agent asking whether to build something; this
  is the same rule for a QA agent, so the test it reaches the user by is
  what the question changes about the product — not which role asked it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A QA agent's question reaches the user when the answer changes what the product should do",
       criterion: 1986 do
    scenario "a QA agent asks whether a gap it found should actually be fixed" do
      given_ "a QA agent asking something only the user can decide", context do
        reply = join_working_copy(context, "/tmp/spex-1986", "the QA checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        qa_agent = Fixtures.running_agent(scope, role: "qa", working_copy: "/tmp/spex-1986")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: qa_agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "found a gap, not sure it is a bug",
              questions: [
                %{
                  "question" =>
                    "The export skips archived invoices — is that a bug, or the intended behaviour?",
                  "options" => [%{"label" => "bug, fix it"}, %{"label" => "intended, leave it"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent cannot settle it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.question_id,
              reason: "whether a gap in the export is a bug or intended behaviour is a product call",
              as: "Archived invoices are left out of the export. Is that a bug to fix, or how it should work?"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "it reaches the user, because the answer changes what the product should do",
            context do
        {:ok, _live, html} = live(context.conn, "/app/questions/#{context.question_id}")

        assert html =~ "Is that a bug to fix, or how it should work?",
               """
               The QA agent's question never reached the user, even though only
               they can say whether a gap is a bug or the intended behaviour.

               the question page:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
