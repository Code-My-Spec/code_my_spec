defmodule CodeMySpecSpex.Story538.Criterion3108Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 3108 — Finishing work that unblocks another role wakes that role.

  Rule R12: a role whose work becomes available is sent the menu.

  ## The hole this closes, and it is the one that made the loop unusable

  R6 lets an agent whose own queue is empty stop, and R10 makes that queue its
  own role's. Both are right, and together they strand everybody: coding drains
  what it can do and goes quiet, product later finishes a spec that unblocks
  three coding requirements, and nothing in the system has any reason to look at
  the coding agent again. The copy is staffed, switched on, and asleep.

  So finishing work is what wakes the roles it unblocked. Nothing is assigned —
  the woken agent gets the menu, the same one its own stop would have produced,
  and chooses.

  ## Why this is not a leader

  A leader would be a fifth thing deciding what everyone does next, which is the
  orchestrator John declined earlier in this same story: *"I'm dubious our
  orchestrator will make better decisions than the model."* The graph already
  holds the ordering. What was missing was not a decider but a doorbell.

  ## What is asserted

  That an agent which did not do the work hears about it, and that the wake
  offers the call rather than naming a requirement.

  Surface: `evaluate_task` completing a real task, and what lands in the other
  agent's own conversation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A role whose work becomes available is sent the menu" do
    scenario "Finishing work that unblocks another role wakes that role" do
      given_ "the project chain is past kickoff, so role work is the frontier",
             context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component
      given_ :story_linked_to_component
      # Its evaluation passes trivially, which is what this scenario needs: the
      # wake fires on a task *completing*, and a task that fails evaluation
      # leaves the same work outstanding for the same role — correctly sending
      # nobody anything.
      given_ :context_spec_task_started

      given_ "a coding agent on the copy, working and idle", context do
        coding = Fixtures.running_agent(context.scope, role: "coding")

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: true},
            frame
          )

        # The graph the menu counts from. Without it every role reads zero, the
        # wake is silent, and it would be silent for a reason that has nothing
        # to do with R12.
        {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok,
         context
         |> Map.put(:coding, coding.id)
         |> Map.put(:heard_before, heard(context.scope, coding.id))}
      end

      when_ "a task on this copy is finished", context do
        # Through the stop hook, which is how a task actually completes: the
        # agent stops, `TaskEvaluator` judges the active task, and a passing
        # evaluation completes it. Calling `evaluate_task` directly would need a
        # task id the agent never handles either.
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post(~p"/api/hooks/stop", %{"session_id" => context.session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :heard_after, heard(context.scope, context.coding))}
      end

      then_ "the coding agent is sent the menu", context do
        assert context.heard_after > context.heard_before,
               "the coding agent heard nothing when a task on its own copy " <>
                 "completed. An agent that stopped because its queue was empty — " <>
                 "which is right — has nothing that would ever bring it back, and " <>
                 "the copy stays staffed, switched on, and asleep. " <>
                 "before=#{context.heard_before} after=#{context.heard_after}"

        {:ok, context}
      end

      then_ "and nothing hands it a particular requirement", context do
        said = latest(context.scope, context.coding)

        assert said =~ "get_next_requirement",
               "the wake did not offer the call that opens the work. Got: #{said}"

        refute said =~ "start_task",
               "the wake named a requirement to start. R12 delivers the menu and " <>
                 "the agent chooses — the graph decides what is available, and " <>
                 "nobody is put in charge of anybody. Got: #{said}"

        {:ok, context}
      end
    end
  end

  # How many things the orchestrator has said to this agent.
  defp heard(scope, agent_id), do: length(Fixtures.orchestrator_actions(scope, agent_id))

  defp latest(scope, agent_id) do
    scope
    |> Fixtures.orchestrator_actions(agent_id)
    |> List.last()
    |> inspect()
  end
end
