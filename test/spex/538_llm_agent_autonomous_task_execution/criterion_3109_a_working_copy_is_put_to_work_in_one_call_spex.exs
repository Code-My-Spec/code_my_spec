defmodule CodeMySpecSpex.Story538.Criterion3109Spex do
  @moduledoc """
  Story 538 — LLM Agent Autonomous Task Execution
  Criterion 3109 — A working copy is put to work in one call, and stopped the
  same way.

  Rule R13: continuous mode is turned on and off deliberately. An MCP tool
  starts a working copy's agents working, and a control on the working copy page
  turns it on and off for a person watching.

  ## The state this closes

  Continuous mode governs whether an agent keeps working when its turn ends, and
  it had no front door. The only way in was an agent happening to work the
  `start_implementation` task; the only way out was `tap_out`, which asks a
  human. Measured on 2026-09-05: 103 sessions in the database, every one of them
  `false`, because nothing had ever put one anywhere else.

  ## Per copy, and both directions

  A checkout is working or it is not — that is the unit somebody decides about,
  and switching three staffed agents on one at a time is not a decision anyone
  wants to make three times.

  Both directions in one criterion, because a switch that only goes on is a
  trap: an agent in a loop nobody can leave is the failure `tap_out` exists for,
  arriving through a door with no handle on the inside.

  Turning it off is not killing. The agents stay on the copy with their
  conversations and can be put back to work; `offboard_working_copy` ends
  things.

  Surface: the `set_working_copy_loop` MCP tool, and the agent rows it switches.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetWorkingCopyLoop
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @roles ~w(product coding qa)

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Continuous mode is turned on and off deliberately" do
    scenario "A working copy is put to work in one call, and stopped the same way" do
      given_ :synced_context_component

      given_ "a working copy staffed with agents that are not working", context do
        # The three roles an epic's copy is staffed with. Not one agent: what
        # this criterion is about is a switch that moves a whole checkout, and
        # one agent cannot tell "moved them all" from "moved the one I looked
        # at".
        agents = Enum.map(@roles, &Fixtures.running_agent(context.scope, role: &1))

        assert working(context.scope) == [],
               "the premise is a staffed copy nobody has put to work; if these " <>
                 "started in the loop the switch below proves nothing"

        {:ok, Map.put(context, :staffed, Enum.map(agents, & &1.id))}
      end

      when_ "the tool that starts it working is called", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: true},
            frame
          )

        {:ok, context |> Map.put(:started, inspect(response))}
      end

      then_ "its agents are working", context do
        assert Enum.sort(working(context.scope)) == Enum.sort(context.staffed),
               "the tool reported success and left some of the copy's agents out of " <>
                 "the loop. A switch that moves only part of a checkout leaves the " <>
                 "rest stopping while the others carry on — a split nobody asked for " <>
                 "and nothing displays."

        {:ok, context}
      end

      and_ "the reply says nothing was assigned to anyone", context do
        assert context.started =~ "Nothing has been assigned",
               "starting the loop reads as handing out work. It does not: each agent " <>
                 "is handed a menu and chooses. Got: #{context.started}"

        {:ok, context}
      end

      and_ "the same control turns them off again", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          SetWorkingCopyLoop.execute(
            %{working_copy_id: context.scope.active_working_copy_id, working: false},
            frame
          )

        assert working(context.scope) == [],
               "the agents stayed in the loop after being told to stop. A mode that " <>
                 "only goes on is one nobody can leave without asking a human, which " <>
                 "is the door `tap_out` exists to work around."

        {:ok, context}
      end
    end
  end

  # Which of this project's agents are in the loop, read back off the rows.
  defp working(scope) do
    scope
    |> Fixtures.list_agents()
    |> Enum.filter(&(&1.continuous == true))
    |> Enum.map(& &1.id)
  end
end
