defmodule CodeMySpecSpex.Story1050.Criterion3203Spex do
  @moduledoc """
  Story 1050 — An agent is told only about work for its own role.
  Criterion 3203 — Looking is allowed, being pushed is not.

  The distinction the story turns on, in five words. Push is scoped; pull is
  not.

  An agent that went looking has spent the turn deciding to look, which is the
  cost this story is about and it chose to pay it. An agent that was told has
  had the cost imposed. Same information, opposite economics — so the filter
  belongs on delivery and nowhere near the read.

  It matters concretely: a coding agent debugging a failure it caused wants the
  QA agent's findings, and a system that hides them makes it re-derive what is
  already written down. `list_agent_work` and `check_machinery` both exist
  because seeing across the fleet is useful; scoping the read would undo them
  for everybody except the role that filed the thing.

  Both Thens against the same finding, because the pair is the claim. Readable
  and never pushed is the state; either half alone is a different product.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.IdleAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The role filter scopes what an agent is told, never what it may do" do
    scenario "Looking is allowed, being pushed is not" do
      given_ "the project chain is past kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ "a coding agent told nothing about QA work", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")
        Fixtures.running_agent(context.scope, role: "qa")
        context = context |> start_session() |> put_to_work()

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:before, heard_count(context, coding.id))}
      end

      given_ "a finding the QA agent filed", context do
        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "the ledger rounds the wrong way on refunds",
              description: "found while testing the refund path",
              severity: "medium",
              scope: "qa"
            },
            frame(context)
          )

        refute filed.isError, "the premise is a finding that exists: #{response_text(filed)}"

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context}
      end

      when_ "the coding agent asks to see the QA agent's findings", context do
        {:reply, reply, _frame} = ListIssues.execute(%{}, frame(context))

        {:ok, context |> Map.put(:reply, reply) |> Map.put(:text, response_text(reply))}
      end

      then_ "it can read them", context do
        refute context.reply.isError, "the read was refused outright: #{context.text}"

        assert context.text =~ "the ledger rounds the wrong way on refunds",
               """
               The coding agent cannot see a finding about code it wrote.

               It is debugging a failure it caused and the description is
               already written down; hiding it makes the agent re-derive what
               somebody else has already established. `list_agent_work` and
               `check_machinery` exist because seeing across the fleet is
               useful — scoping the read undoes them for everybody except
               whoever filed the thing.

               #{context.text}
               """

        {:ok, context}
      end

      then_ "and it was still never notified about them", context do
        refute_told_anything(
          context,
          context.coding,
          context.before,
          """
          The finding was pushed to the coding agent as well as being readable
          by it.

          Push and pull have opposite economics on the same information. An
          agent that went looking spent the turn deciding to look and chose to
          pay for it; an agent that was told had the cost imposed. The filter
          belongs on delivery, and being readable is not a reason to deliver.
          """
        )

        {:ok, context}
      end
    end
  end
end
