defmodule CodeMySpecSpex.Story1054.Criterion3270Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3270 — Every agent's current work in one view.

  The first spex on this story, so it chooses the surface the rest inherit.
  Written down because the module it names does not exist yet: what is written
  here becomes the public API.

  ## Why a new tool rather than more on `list_agents`

  `Agents.Tools.ListAgents` answers "what is running, and on which working
  copy" — id, engine, provider, root, status. That is the fleet's *lifecycle*,
  and every caller of it wants exactly that: `start_agent` and `stop_agent` sit
  beside it and act on the same handles.

  This story asks a different question. Criterion 3275 says the answer must
  carry the open task, the time of the last message, what the agent is blocked
  on, and whether work is in flight — four facts per agent, none of them about
  lifecycle. Folding them into `list_agents` would make one listing answer two
  questions and charge every caller that wants the cheap one for the expensive
  one, which is the same argument that kept questions off it in story 1053.

  So `CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork`, beside
  `list_open_questions` on the same server. The main agent's view across its
  agents is one context's job, and this is the second half of it.

  ## What this criterion claims, and what it leaves to the others

  Only that all three appear and that each names its work. What "work" is shown
  as, how idle differs from broken, and what happens to an agent that has gone
  quiet are 3271, 3272 and 3274 — this one fails if any agent is missing from
  the view at all.

  The second half of the criterion — "the main agent did not have to ask any of
  them" — is what makes it a listing rather than three calls, and it is asserted
  structurally: one call, three agents in the reply. A scenario that called the
  tool per agent would satisfy the words and miss the point.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The join runs in a channel process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One call answers what the whole fleet is doing" do
    scenario "three agents of different kinds are running" do
      given_ "a coding, a QA and a product agent, each holding a task", context do
        reply = join_working_copy(context, "/tmp/spex-3270", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agents =
          for {role, requirement} <- [
                {"coding", "implementation_file"},
                {"qa", "qa_complete"},
                {"product", "three_amigos_complete"}
              ] do
            agent =
              CodeMySpecSpex.Fixtures.running_agent(scope,
                role: role,
                working_copy: "/tmp/spex-3270"
              )

            {_agent, _task} =
              CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
                requirement_name: requirement
              )

            {role, requirement, agent}
          end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agents, agents)}
      end

      when_ "the main agent looks at what its agents are doing", context do
        # One call. The criterion's "did not have to ask any of them" is this
        # line: asking per agent would satisfy the words and lose the claim.
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "each of the three is listed with the work it holds", context do
        for {role, requirement, agent} <- context.agents do
          assert context.view =~ agent.id,
                 """
                 The #{role} agent is not in the view at all.

                 A view that is missing an agent is worse than no view: the main
                 agent reads it, sees everything accounted for, and never learns
                 that one of its own is unrepresented. Every other criterion on
                 this story is about what is *said* about an agent — this one is
                 about whether it is there to be said about.

                 view:
                 #{context.view}
                 """

          assert context.view =~ requirement,
                 """
                 The #{role} agent is listed with no work named against it.

                 "Where the project's effort is going" is the story, and an
                 agent listed as merely running answers it no better than the
                 process table does.

                 view:
                 #{context.view}
                 """
        end

        {:ok, context}
      end
    end
  end
end
