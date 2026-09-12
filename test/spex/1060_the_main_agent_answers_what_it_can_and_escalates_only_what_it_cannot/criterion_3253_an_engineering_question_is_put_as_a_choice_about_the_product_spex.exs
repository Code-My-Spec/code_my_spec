defmodule CodeMySpecSpex.Story1060.Criterion3253Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3253 — An engineering question is put as a choice about the
  product.

  Rule: what reaches the user is a decision they can make.

  The story's own sentence: the user is interrupted by decisions rather than by
  engineering detail. 3252 establishes that some questions must reach them; this
  says reaching them is not enough — a question arriving as module names and a
  stack trace is technically delivered and practically useless, and the person
  it reached cannot answer it without asking somebody what it means.

  That failure looks like success from every side. The agent escalated, the
  question is in the inbox, nothing errored — and it sits there, because
  answering it would take a conversation nobody has started.

  ## Translated, not stripped

  The detail stays. A user who wants to know why is entitled to, and an
  escalation that discards the original leaves the answer unmoored from the
  thing it decides — and the agent that asked cannot check its own question
  survived the trip.

  So both are asserted: the product framing is there, and the original is still
  reachable. What must not be true is that the decision *requires* the detail.

  ## Read on the question's own page

  The inbox renders a summary and links onward; the form somebody answers — and
  the detail beside it — is at `/app/questions/<id>`. That is where the decision
  is actually made, so it is where the criterion is checked.
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

  @engineering "Ecto.ConstraintError on invoices_account_id_fkey in " <>
                 "CodeMySpec.Billing.InvoiceRepository.insert/2 — cascade or restrict?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The user is shown the decision, not the stack trace" do
    scenario "an agent's question is module names and error output" do
      given_ "an agent asking an engineering question", context do
        reply = join_working_copy(context, "/tmp/spex-3253", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3253")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "foreign key behaviour",
              questions: [
                %{
                  "question" => @engineering,
                  "options" => [%{"label" => "cascade"}, %{"label" => "restrict"}]
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

      when_ "the main agent passes it up", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EscalateQuestion.execute(
            %{
              question_id: context.question_id,
              reason: "only the user can say what should happen to a customer's invoices",
              as:
                "When someone deletes a customer, should their invoices go too, or should " <>
                  "we refuse to delete a customer who still has any?"
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context}
      end

      then_ "the user is shown what the decision changes about their project",
            context do
        {:ok, _live, html} = live(context.conn, "/app/questions/#{context.question_id}")

        assert html =~ "should their invoices go too",
               """
               The user was handed a stack trace and asked to choose.

               Technically delivered and practically useless: the person it
               reached cannot answer without asking somebody what it means, so
               it sits in the inbox while everything about the delivery looks
               successful.

               the question page:
               #{html}
               """

        {:ok, context}
      end

      then_ "and the engineering detail is available but not required", context do
        {:ok, _live, html} = live(context.conn, "/app/questions/#{context.question_id}")

        assert html =~ "invoices_account_id_fkey",
               """
               The original question was discarded in the translation.

               A user who wants to know why is entitled to, and an escalation
               that throws the original away leaves the answer unmoored from the
               thing it decides — the agent that asked cannot even check its
               question survived the trip.

               the question page:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
