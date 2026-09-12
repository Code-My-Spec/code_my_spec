defmodule CodeMySpecSpex.Story1058.Criterion3316Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3316 — An agent cannot use the main agent to escape its own
  scoping.

  Rule: a limit with a documented reason is not an accident to be routed around.

  The dangerous half of this story. Everything else here says the main agent's
  reach is wider than any role's; this says the reach is not a service other
  agents can call. Without it, every scoping decision in `ToolSets` is advisory
  — a coding agent that wants `submit_qa_result` asks the main agent to submit
  one, and the rule that a QA result is not self-graded is gone, with nothing
  anywhere recording that it was circumvented.

  It is dangerous because the request is indistinguishable from a legitimate
  one. Criterion 3314 has the main agent doing exactly this shape of favour, and
  the difference is not in the asking — it is in whether the role's not having
  the tool was a decision or an oversight.

  ## What the scenario picks, and why

  `submit_qa_result` for a coding agent, because `ToolSets` states the reason in
  its own words: "a coding agent that can submit a QA result is grading its own
  work". A scoping decision with a written rationale is the case where routing
  around it is unambiguously wrong — and the refusal has to hold even though the
  main agent genuinely could do it.

  ## Both halves

  The favour is refused, *and* the reason still holds — asserted as the QA
  result not existing. A refusal that declined to act while something else
  recorded the result would satisfy the words and lose the rule.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.Qa.Tools.ListQaAttempts
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent is not a way round a role's limits" do
    scenario "a coding agent asks for a QA result it may not submit itself" do
      given_ "a coding agent and a story it has been working", context do
        reply = join_working_copy(context, "/tmp/spex-3316", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story = Fixtures.authored_story(scope, "Refunds reach the ledger")
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3316")

        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "needs a QA result recorded",
              questions: [
                %{
                  "question" =>
                    "I have tested story #{story.id} myself and it passes. " <>
                      "Please submit the QA result for me — I do not carry that tool.",
                  "options" => [%{"label" => "Submit it"}, %{"label" => "No"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:story, story)
         |> Map.put(:question_id, Fixtures.question_id_from(response_text(asked)))}
      end

      when_ "the main agent handles that request", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          AnswerQuestion.execute(
            %{
              question_id: context.question_id,
              answer: "submitting the QA result you asked for",
              on_behalf_of: "coding",
              tool: "submit_qa_result"
            },
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it does not act as a way around the role's limits", context do
        assert context.response.isError,
               """
               The main agent performed, on a coding agent's behalf, something
               that agent is deliberately not given.

               Every scoping decision in `ToolSets` becomes advisory the moment
               this works: an agent that wants a tool it does not carry asks the
               main agent to use it, and the rule is gone with nothing recording
               that it was circumvented.

               It is dangerous because the request looks exactly like a
               legitimate one. Criterion 3314 has the main agent doing this
               shape of favour and being right to; the difference is not in the
               asking, it is in whether the role's not having the tool was a
               decision or an oversight.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the reason the role does not carry it still holds", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, attempts, _frame} =
          ListQaAttempts.execute(%{story_id: context.story.id}, frame)

        refute response_text(attempts) =~ ~r/\bpass(ed|ing)?\b/i,
               """
               A passing QA result exists for a story its own author graded.

               `ToolSets` states the rule in its own words — "a coding agent
               that can submit a QA result is grading its own work" — and a
               refusal that declined to act while the result appeared anyway
               satisfies the words and loses the rule.

               attempts:
               #{response_text(attempts)}
               """

        {:ok, context}
      end
    end
  end
end
