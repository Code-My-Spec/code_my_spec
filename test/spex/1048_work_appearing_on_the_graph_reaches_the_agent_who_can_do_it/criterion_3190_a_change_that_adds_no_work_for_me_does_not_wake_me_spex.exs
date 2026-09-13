defmodule CodeMySpecSpex.Story1048.Criterion3190Spex do
  @moduledoc """
  Story 1048 — Work appearing on the graph reaches the agent who can do it.
  Criterion 3190 — A change that adds no work for me does not wake me.

  Both filters at once — wrong role *and* wrong checkout — which is what makes
  this cheap to get half right. An implementation that filters on role alone
  passes this, and an implementation that filters on checkout alone passes it
  too. It is here as the compound case; 1047's 3179 and 3184 are the two halves
  separately.

  "And it remains idle" is the second Then because the two failures are
  different. A message it ignores costs tokens on the next turn. A message it
  acts on costs a whole turn, spent reading a graph that has nothing in it for
  this agent — and on a busy project the graph changes constantly.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent is woken only by work inside its own role and checkout" do
    scenario "A change that adds no work for me does not wake me" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a coding agent running and idle", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        context = context |> start_session() |> put_to_work()
        :ok = Fixtures.watch_graph(context.scope)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      when_ "the graph changes in a way that adds only QA work on another working copy",
            context do
        other = join_working_copy(context, "/tmp/spex-3190-qa", "somebody else's checkout")
        other_scope = %{context.scope | active_working_copy_id: other.working_copy_id}

        Fixtures.running_agent(other_scope, role: "qa", working_copy: "/tmp/spex-3190-qa")

        story = Fixtures.released_story(other_scope, "Refunds reach the ledger")
        Fixtures.record_deploy(other_scope, story.id, "dev")

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      then_ "the coding agent is sent nothing", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          A change that added neither work of this agent's role nor work on
          this agent's checkout woke it anyway.

          Both filters are wrong here at once, which is what makes this cheap
          to get half right: filtering on role alone passes it, and filtering
          on checkout alone passes it too.
          """
        )

        {:ok, context}
      end

      then_ "and it remains idle", context do
        {:reply, view, _frame} = ListAgentWork.execute(%{}, frame(context))
        entry = entry_for(response_text(view), context.coding)

        assert entry, "the agent is gone from the fleet listing, so 'idle' is true of nothing"

        refute entry =~ "has not finished",
               """
               The agent took a turn over a change with nothing in it for it.

               A message it ignores costs tokens on the next turn. A message it
               acts on costs a whole turn — and on a busy project the graph
               changes constantly.

               #{entry}
               """

        {:ok, context}
      end
    end
  end

  defp entry_for(view, agent_id) do
    view
    |> String.split(~r/\n(?=\s*Agent:)/)
    |> Enum.find(&String.contains?(&1, agent_id))
  end
end
