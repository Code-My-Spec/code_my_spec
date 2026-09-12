defmodule CodeMySpecSpex.Story1054.Criterion3273Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3273 — A question about all the agents at once is answerable.

  Rule: the fleet is a thing you can ask about, not a set of things you ask
  one at a time.

  The question that diagnosed a four-hour outage was "has any agent called a
  tool since the server restarted". No per-agent view answers it — you can read
  three agents in turn and still not have it, because the answer is a property
  of the set. That is this criterion, and it is why the story is fleet-level.

  3270 already says one call returns every agent. This says the call spans
  *checkouts*: the agents of one project are spread across its working copies,
  and a view scoped to the copy the main agent happens to be standing on answers
  the same question about a subset while looking exactly as complete.

  Same shape as criterion 3261 on story 1053, and the same reasoning: the main
  agent's view is the project's, not a checkout's. Kept separate from 3270
  because the obvious implementation — scope to `active_working_copy_id`, as
  nearly everything else in this codebase correctly does — passes 3270 and fails
  here.

  The scenario reads from the *first* checkout deliberately. The main agent
  always has some checkout on its scope, so asking from a scope with no checkout
  would pass against a per-copy implementation and prove nothing.
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

  spex "One answer covers every agent on the project" do
    scenario "agents are running on two of the project's working copies" do
      given_ "an agent on each of two checkouts of the same project", context do
        copies =
          for {root, label, role, requirement} <- [
                {"/tmp/spex-3273-a", "the first", "coding", "implementation_file"},
                {"/tmp/spex-3273-b", "the second", "qa", "qa_complete"}
              ] do
            reply = join_working_copy(context, root, label)
            scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

            agent = CodeMySpecSpex.Fixtures.running_agent(scope, role: role, working_copy: root)

            {_agent, _task} =
              CodeMySpecSpex.Fixtures.agent_task_fixture(scope, agent,
                requirement_name: requirement
              )

            %{label: label, scope: scope, agent: agent}
          end

        {:ok, Map.put(context, :copies, copies)}
      end

      when_ "the main agent asks about its agents from one of the checkouts", context do
        [first | _] = context.copies

        frame = %Frame{assigns: %{current_scope: first.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "both checkouts' agents are in the one answer", context do
        for %{label: label, agent: agent} <- context.copies do
          assert context.view =~ agent.id,
                 """
                 The agent on #{label} checkout is missing from the answer.

                 A view scoped to the asking checkout satisfies criterion 3270
                 and fails here, which is why this criterion exists separately.
                 The main agent runs on one checkout and is responsible for all
                 of them, so a view narrowed to where it happens to be standing
                 answers a question about a subset while looking exactly as
                 complete as the real answer.

                 "Has any agent done anything since the restart" is the question
                 that found a four-hour outage, and it cannot be answered from a
                 view that silently drops half the fleet.

                 view:
                 #{context.view}
                 """
        end

        {:ok, context}
      end
    end
  end
end
