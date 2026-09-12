defmodule CodeMySpecSpex.Story1054.Criterion3271Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3271 — The work is named, not just the state.

  Rule: a listing of agents is answerable in the project's own words.

  3270 says all three agents appear with the work they hold, and a view that
  prints a requirement name against each satisfies it. This says the requirement
  name is not enough on its own: `implementation_file` names a step in our
  pipeline and says nothing about what the project is getting, and the main
  agent's whole job is to be able to tell somebody that.

  So the story is named too. They are separate criteria because a view can list
  every agent correctly and still be unreadable — the failure here is not a
  missing agent but an answer the main agent cannot pass on without going and
  looking the story up, which is the errand this story exists to remove.

  The story title is the assertion rather than its id for exactly that reason.
  An id is a second lookup wearing the costume of an answer.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "What an agent is doing reads as work, not as a pipeline step" do
    scenario "a coding agent holds a task on a story" do
      given_ "a coding agent with an open task on a named story", context do
        reply = join_working_copy(context, "/tmp/spex-3271", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          CodeMySpecSpex.Fixtures.authored_story(scope, "Customers can cancel a subscription")

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3271"
          )

        {_agent, _task} =
          CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            story_id: story.id
          )

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:story, story)
         |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at what that agent is doing", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the story and the task are both named", context do
        assert context.view =~ "implementation_file",
               """
               The agent's task is not named.

               view:
               #{context.view}
               """

        assert context.view =~ "Customers can cancel a subscription",
               """
               The agent's work is reported as a pipeline step with no story
               behind it.

               `implementation_file` is true and useless on its own: it says
               which stage the work is at and nothing about what the project is
               getting, so the main agent cannot answer "where is the effort
               going" without going and looking the story up — which is the
               errand this story exists to remove.

               A story id would not fix it either. An id is a second lookup
               wearing the costume of an answer.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
