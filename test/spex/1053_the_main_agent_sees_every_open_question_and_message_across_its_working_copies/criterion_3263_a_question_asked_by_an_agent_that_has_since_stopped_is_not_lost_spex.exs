defmodule CodeMySpecSpex.Story1053.Criterion3263Spex do
  @moduledoc """
  Story 1053 — The main agent sees every open question and message across its
  working copies.
  Criterion 3263 — A question asked by an agent that has since stopped is not
  lost.

  Rule: a question outlives the process that asked it.

  The one failure here that cannot be noticed from the outside. An unanswered
  question that disappears leaves nothing behind — no entry, no error, no agent
  complaining — and the work it was blocking simply never resumes. Every other
  criterion on this story fails visibly by comparison: a short list is at least
  a list.

  It is also the likeliest thing to get wrong, because stopping an agent is a
  real cleanup path and a question is exactly the sort of thing a cleanup path
  takes with it. An agent is restarted whenever its harness reconnects, its
  machine reboots, or somebody promotes — so "the agent that asked is gone" is
  ordinary rather than exceptional, and a question that cannot survive it is a
  question that rarely survives at all.

  Stopped through `stop_agent`, which is how an agent actually stops. A scenario
  that deleted the row would be testing its own delete.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StopAgent
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A question survives the agent that raised it" do
    scenario "the asking agent is stopped before anyone answers" do
      given_ "an agent with an open question", context do
        reply = join_working_copy(context, "/tmp/spex-3263", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3263"
          )

        frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, response, _frame} =
          AskUserQuestion.execute(
            %{
              title: "a question raised before stopping",
              questions: [
                %{
                  "question" => "Should the migration run before or after the swap?",
                  "options" => [%{"label" => "Before"}, %{"label" => "After"}]
                }
              ]
            },
            frame
          )

        refute response.isError, inspect(response)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "that agent is stopped", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StopAgent.execute(%{agent_id: context.agent.id}, frame)

        refute response.isError,
               "the agent had to actually stop for this to mean anything:\n" <>
                 inspect(response)

        {:ok, context}
      end

      then_ "the question is still waiting", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListOpenQuestions.execute(%{}, frame)

        refute response.isError, inspect(response)

        assert response_text(response) =~
                 "Should the migration run before or after the swap?",
               """
               The question disappeared with the agent that asked it.

               Nothing else reports this. There is no entry, no error, and no
               agent left to complain — the work the question was blocking
               simply never resumes, and the only evidence is a project that
               quietly stopped moving.

               An agent is restarted whenever its harness reconnects, its
               machine reboots, or somebody promotes. So this is the ordinary
               case rather than the exceptional one, and a question that cannot
               survive it is a question that rarely survives.

               listing:
               #{response_text(response)}
               """

        {:ok, context}
      end
    end
  end
end
