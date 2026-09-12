defmodule CodeMySpecSpex.Story1054.Criterion3275Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3275 — The main agent reasons from the parts rather than reading a
  verdict.

  Rule: the view reports; the main agent judges.

  This is the design constraint the rest of the story hangs off, and it is a
  refusal as much as a requirement. Every other criterion asks for something to
  be visible; this one says the view must not go the last step and decide what
  it all means.

  The reason is that the last step is wrong often enough to matter and is
  invisible when it is. "Stalled" computed from a silence threshold calls a
  streaming agent dead (3279) and a tapped-out one broken (3278), and in both
  cases the main agent has no way to disagree, because the parts the verdict was
  computed from are gone. A verdict is lossy and does not say so.

  So four parts, named by the criterion: the open task, when the agent last
  said anything, what it is blocked on, and whether work is in flight. Each one
  is asserted separately — a view can carry three and drop the fourth, and the
  dropped one is always the one the case in front of you turns on.

  ## Against a plausible good-faith implementation

  The obvious thing to build is a status field: `:working`, `:idle`, `:stalled`.
  It reads better, it is shorter, and it is what a dashboard would do. It also
  satisfies 3270, 3271 and 3272 completely. This criterion exists to rule it
  out, and it is the only one that does.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The parts are handed over, not a conclusion drawn from them" do
    scenario "an agent holds a task and has been quiet for a while" do
      given_ "an agent with an open task, quiet for half an hour, waiting on an answer",
             context do
        reply = join_working_copy(context, "/tmp/spex-3275", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story = CodeMySpecSpex.Fixtures.authored_story(scope, "Refunds are approved in one place")

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3275"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            story_id: story.id,
            started_at: DateTime.add(DateTime.utc_now(), -40 * 60, :second)
          )

        :ok = CodeMySpecSpex.Fixtures.agent_said(scope, agent, "looking at the approval path")
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 30 * 60)

        # What it is blocked on, raised the way this agent raises one — so the
        # question is attributed to it rather than merely existing on the
        # project. A question with no asker cannot be shown against an agent.
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, asked, _frame} =
          AskUserQuestion.execute(
            %{
              title: "blocked on a decision",
              questions: [
                %{
                  "question" => "Who signs off a refund over 500?",
                  "options" => [%{"label" => "Support"}, %{"label" => "Finance"}]
                }
              ]
            },
            asking
          )

        refute asked.isError, inspect(asked)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "all four parts are there", context do
        assert context.view =~ "implementation_file",
               "the open task is missing:\n#{context.view}"

        assert context.view =~ ~r/last (said|spoke|heard|message)/i,
               """
               When the agent last said anything is missing.

               It is the part every judgement about silence is made from, and
               without it the main agent can only accept or reject whatever the
               view concluded.

               view:
               #{context.view}
               """

        assert context.view =~ ~r/blocked|waiting/i,
               "what the agent is blocked on is missing:\n#{context.view}"

        assert context.view =~ ~r/in flight/i,
               """
               Whether work is in flight is missing.

               This is the part that most often decides the case and is the
               easiest to leave out, because it is the only one that is not a
               row in a table — and it is exactly what separates a stalled agent
               from one waiting on a model (criterion 3279).

               view:
               #{context.view}
               """

        {:ok, context}
      end

      then_ "and no verdict is offered in place of them", context do
        refute context.view =~ ~r/\b(stalled|stuck|dead|unhealthy|healthy)\b/i,
               """
               The view has drawn its own conclusion about this agent.

               The obvious implementation is a status field — `:working`,
               `:idle`, `:stalled` — and it reads better than four lines of
               parts. It also satisfies every other criterion on this story.

               It is wrong because the last step is wrong often enough to
               matter and invisible when it is: the same silence threshold that
               produces "stalled" here calls a streaming agent dead (3279) and a
               tapped-out one broken (3278). Once the verdict is computed the
               parts it came from are gone, so the main agent cannot disagree
               with it — a verdict is lossy and does not say so.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
