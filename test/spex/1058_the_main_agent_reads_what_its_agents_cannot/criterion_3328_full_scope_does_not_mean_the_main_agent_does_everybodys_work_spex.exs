defmodule CodeMySpecSpex.Story1058.Criterion3328Spex do
  @moduledoc """
  Story 1058 — The main agent reads what its agents cannot.
  Criterion 3328 — Full scope does not mean the main agent does everybody's
  work.

  Rule: the wider scope is for what cannot be delegated, not for what is slow.

  3327's counterweight, and the one that keeps the fleet a fleet. A main agent
  that may do anything, watching an agent work slowly on something it could
  finish itself, has every incentive to take over — and taking over is right in
  exactly the cases 3327 names and wrong in every other.

  The failure is gradual and looks like productivity throughout. Each individual
  takeover is defensible; the end state is one agent doing all the work while
  three sit idle, with no moment where anybody decided that. It also destroys
  what the roles are for: a coding agent's work is reviewed by QA because it is
  a coding agent's, and work the main agent did itself has no such counterpart.

  ## The discrimination

  A coding agent with a task it carries the tools for. That is the whole test:
  capable and in progress. Whether it is slow is beside the point, and the
  criterion says so — "not for what it would rather not wait for".

  ## Asserted as the task staying put

  Not as the main agent declining to say something. The observable is who holds
  the work afterwards: the agent still has it, and the main agent has not
  produced the artefact in its place.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.MainAgent.Tools.TakeOverWork
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work a role can do stays with the role" do
    scenario "a coding agent holds a task it carries the tools for" do
      given_ "a coding agent working a story it is equipped for", context do
        reply = join_working_copy(context, "/tmp/spex-3328", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story = Fixtures.authored_story(scope, "Refunds reach the ledger")
        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3328")

        {_agent, task} =
          Fixtures.agent_task_fixture(scope, agent,
            requirement_name: "implementation_file",
            story_id: story.id
          )

        # Slow, and capable. Slowness is the temptation and the criterion says
        # in its own words that it is not a reason.
        :ok = Fixtures.agent_said(scope, agent, "working through the ledger writer")
        :ok = Fixtures.age_agent_messages(scope, agent, 40 * 60)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:agent, agent)
         |> Map.put(:task, task)}
      end

      when_ "the main agent could do that work itself", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          TakeOverWork.execute(
            %{agent_id: context.agent.id, task_id: context.task.id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "it leaves the work with the agent whose job it is", context do
        assert context.response.isError,
               """
               The main agent took work off an agent that was capable of it.

               Each individual takeover is defensible and the end state is one
               agent doing everything while three sit idle, with no moment where
               anybody decided that. It also removes what the roles are for: a
               coding agent's work is reviewed by QA because it is a coding
               agent's, and work the main agent did itself has no counterpart to
               check it.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end

      then_ "and the task is still the agent's", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame)

        entry =
          response_text(view)
          |> String.split(~r/\n(?=\s*Agent:)/)
          |> Enum.find("", &String.contains?(&1, context.agent.id))

        assert entry =~ "implementation_file",
               """
               The refusal left the agent without its task anyway.

               Declining to take the work over and detaching it from the agent
               are the same outcome from the agent's side: it comes back to
               nothing to do, and the work is somewhere nobody is responsible
               for it.

               entry:
               #{entry}
               """

        {:ok, context}
      end
    end
  end
end
