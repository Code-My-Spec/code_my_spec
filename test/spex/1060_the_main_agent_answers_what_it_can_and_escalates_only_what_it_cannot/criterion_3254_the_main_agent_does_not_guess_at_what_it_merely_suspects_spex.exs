defmodule CodeMySpecSpex.Story1060.Criterion3254Spex do
  @moduledoc """
  Story 1060 — The main agent answers what it can and escalates only what it
  cannot.
  Criterion 3254 — The main agent does not guess at what it merely suspects.

  Rule: an answer with nothing behind it is refused, however plausible.

  The criterion the basis exists for. 3251 and 3255 are cases where the project
  records the answer; this is the case where it does not, and the answer would
  read exactly the same.

  A confident guess is the most expensive thing this main agent can produce.
  The asking agent has no way to tell it from a looked-up fact — nothing in the
  reply distinguishes them — so it proceeds on it, builds on it, and the error
  compounds through everything downstream while the user's own question is never
  asked. Compare that with escalating: the agent waits, which is visible, and
  somebody answers.

  ## Enforced, not asked for

  This cannot be a guideline. The pressure runs one way — a main agent told to
  spare the user is rewarded for answering — and a rule that depends on the
  thing under pressure choosing to follow it is not a rule.

  So the refusal is the system's: an answer whose basis is `record` is checked
  against the record, and one that is not there is refused with the escalation
  path named.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @question "What is our retention period for deleted invoices?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An answer the project cannot support is refused" do
    scenario "an agent asks something nothing records" do
      given_ "a question the project holds no answer to", context do
        reply = join_working_copy(context, "/tmp/spex-3254", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3254")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "needs a policy nobody has written down",
              questions: [
                %{
                  "question" => @question,
                  "options" => [%{"label" => "30 days"}, %{"label" => "7 years"}]
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

      when_ "the main agent cannot settle it from what it holds", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "7 years — that is the usual figure for financial records",
              basis: "record"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not answer from inference", context do
        assert context.response.isError,
               """
               The main agent answered from what it supposed rather than from
               what the project records.

               A confident guess is the most expensive thing it can produce: the
               asking agent has no way to tell it from a looked-up fact, so it
               proceeds on it, builds on it, and the error compounds through
               everything downstream while the user's own question is never
               asked.

               This cannot be a guideline, either. The pressure runs one way — a
               main agent told to spare the user is rewarded for answering — and
               a rule that depends on the thing under pressure choosing to
               follow it is not a rule.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the question goes to the user", context do
        {:ok, _live, html} = live(context.conn, "/app/notifications")

        assert html =~ @question,
               """
               The guess was refused and the question went nowhere.

               Escalating has a visible cost — the agent waits — and that cost
               is the point: somebody answers. A refusal that ends in silence
               has the same outcome as the guess, minus the answer.

               notifications:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
