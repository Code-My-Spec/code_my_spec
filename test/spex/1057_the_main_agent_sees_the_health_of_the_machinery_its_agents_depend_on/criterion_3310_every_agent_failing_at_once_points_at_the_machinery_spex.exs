defmodule CodeMySpecSpex.Story1057.Criterion3310Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3310 — Every agent failing at once points at the machinery.

  Rule: a fault shared by everything underneath is one fault.

  This is the story's reason for existing, and it is the outage it came from:
  a stale MCP client held by the harness told every agent its tools did not
  exist. Each agent, read on its own, looked individually broken. Nothing put
  the three readings together, and the diagnosis took four hours and raw
  JSON-RPC.

  The cost of the wrong reading is not just delay. Three agents individually
  broken invites three restarts, and each one discards work to fix nothing —
  which is criterion 3292 on story 1056 arrived at from underneath.

  ## Both halves, and the second is the sharp one

  Showing a machinery fault is easy to satisfy while *also* showing three agent
  faults beside it, and that reads as four problems rather than one. So the
  refutation is the real assertion: the agents must not each be presented as
  carrying a fault of their own, because the thing that is wrong is not theirs.

  Scoped to the section that attributes the fault, not to the whole report. An
  agent id elsewhere is not a blaming — criterion 3324 requires the agents on a
  machine to be listed beside its load, precisely so slowness can be read
  against it. What this forbids is the *tools* line naming them, because that
  line is the one that says whose fault it is.

  ## Why three agents and not one

  One agent that cannot call tools is 3311 — a fault that belongs to the agent —
  and the two scenarios differ only in how many. That is the whole discrimination
  the criterion asks for, so a scenario with one agent could not make it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.CheckMachinery
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One fault underneath is reported once, not three times over" do
    scenario "no agent on the machine can call a tool" do
      given_ "three agents on a checkout whose machine reports no tools", context do
        reply = join_working_copy(context, "/tmp/spex-3310", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agents =
          for role <- ["coding", "qa", "product"] do
            Fixtures.running_agent(scope, role: role, working_copy: "/tmp/spex-3310")
          end

        # The harness is holding a dead MCP client. Every agent on it is
        # affected and none of them is the cause.
        Fixtures.record_machine_tools(scope, [])

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agents, agents)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the fault is shown against the machinery", context do
        assert context.report =~ ~r/tools/i and
                 context.report =~ ~r/every agent|all .* agents|3 agents|three agents/i,
               """
               A fault every agent on the machine is suffering is not reported
               as the machine's.

               This is the outage the story came from: a stale MCP client told
               every agent its tools did not exist, each one looked
               individually broken, and nothing put the readings together. Four
               hours and raw JSON-RPC.

               report:
               #{context.report}
               """

        {:ok, context}
      end

      then_ "and it is not presented as several unrelated agent faults", context do
        attribution = section(context.report, "tools:")

        blamed = Enum.count(context.agents, fn agent -> attribution =~ agent.id end)

        assert blamed == 0,
               """
               #{blamed} of the three agents are individually named as faulty
               alongside the machinery fault.

               That reads as four problems rather than one, and it invites the
               remedy for the wrong one: three restarts, each discarding work to
               fix nothing. Naming the machinery *and* the agents satisfies the
               first half of this criterion while failing the reader exactly as
               badly as naming only the agents.

               tools section:
               #{attribution}
               """

        {:ok, context}
      end
    end
  end

  # One labelled section of the report, up to the next one.
  defp section(report, label) do
    report
    |> String.split(~r/^(?=\w+:)/m)
    |> Enum.find("", &String.starts_with?(&1, label))
  end
end
