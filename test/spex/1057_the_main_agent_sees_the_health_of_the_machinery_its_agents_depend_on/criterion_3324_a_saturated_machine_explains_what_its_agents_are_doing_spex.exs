defmodule CodeMySpecSpex.Story1057.Criterion3324Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3324 — A saturated machine explains what its agents are doing.

  Rule: slow is a property of the machine as often as of the agent.

  The reading this prevents is the one that costs most, because the remedy makes
  it worse. Agents on a saturated box are slow and stall; read individually they
  look faulty; restarting them puts *more* work on the box, and the next reading
  is worse than the one that prompted it. It is the only failure on this story
  where acting on the wrong diagnosis actively deepens the fault.

  This project has already been bitten by it from the outside — a test that
  passes forty-one times alone and fails once under a full analyzer sweep, an
  agent's turn that dies with `killed` and nothing in the code to explain it.
  Each time, the answer was the machine, and each time it was found by somebody
  remembering rather than by anything reporting.

  ## Red on the data model, deliberately

  Nothing records machine load. A harness reports its preview, its tools and its
  head commit; it does not report what it is running on. So this criterion is
  not "the report is missing a section" — it is "the fact has never been
  collected", and the spex names the wire message that would carry it,
  `machine_load`, beside `preview_status` which is the same shape of fact
  reported the same way.

  ## Both halves

  The saturation has to be shown, *and* the agents on that machine have to be
  readable against it. A load figure on its own is a number in a report; what
  the criterion asks is that the main agent can attribute the slowness to it,
  which means the two have to appear together.

  ## Not the presence of the word "load"

  The first assertion here was `=~ ~r/load|saturat|memory/i` against the whole
  report, and it passed with the saturation judgement blinded to always-false —
  because the machine section prints the figures either way, under a line
  reading "load is fine". Printing numbers is not the claim; the claim is that
  this machine is carrying more than it can, so that is what is asserted.
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

  spex "A machine under load is reported as the reason its agents are slow" do
    scenario "the box is out of memory and its processors are saturated" do
      given_ "agents on a machine reporting itself saturated", context do
        reply = join_working_copy(context, "/tmp/spex-3324", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])

        agents =
          for role <- ["coding", "qa"] do
            agent = Fixtures.running_agent(scope, role: role, working_copy: "/tmp/spex-3324")
            :ok = Fixtures.agent_said(scope, agent, "starting")
            :ok = Fixtures.age_agent_messages(scope, agent, 30 * 60)
            agent
          end

        # The same shape of fact a harness already reports about its preview and
        # its head commit, for the thing it runs on.
        :ok =
          Fixtures.report_machine_load(scope, %{
            "load_average" => 31.4,
            "cpu_count" => 8,
            "memory_free_mb" => 180
          })

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agents, agents)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the saturation is shown", context do
        # The block for the box these agents are on. The report covers every
        # machine the project touches, and asserting against all of them at once
        # cannot say which one is in trouble — which is the very confusion this
        # criterion is about.
        machine = machine_carrying(context.report, context.agents)

        refute machine =~ ~r/load is fine|has not reported/i,
               """
               A machine running at four times its processor count with 180MB
               free is reported as healthy.

               This is the reading whose remedy deepens the fault: agents on a
               saturated box look individually slow, restarting them puts more
               work on the box, and the next reading is worse than the one that
               prompted it.

               Nothing records machine load today — a harness reports its
               preview, its tools and its head commit, and not what it is
               running on. That is what this criterion is about.

               machine section:
               #{machine}
               """

        assert machine =~ ~r/saturat|carrying more|short of memory/i,
               """
               The machine's figures are printed with nothing saying they are a
               problem.

               31.4 against 8 processors and 180MB free is a box in trouble, and
               a main agent reading two numbers has no way to know that — the
               relationship between them is platform knowledge it cannot
               acquire. Printing them under "load is fine" is worse than not
               printing them.

               machine section:
               #{machine}
               """

        {:ok, context}
      end

      then_ "and the agents on it can be read against it", context do
        assert machine_carrying(context.report, context.agents) != "",
               """
               The machine's load is reported without saying which agents are
               running on it.

               A load figure on its own is a number in a report. The criterion
               asks that slow agents be readable *against* it, which needs the
               two together — otherwise the main agent has one fact about the
               box and a separate list of agents behaving oddly, and joining
               them is the work it was meant to be spared.

               report:
               #{context.report}
               """

        {:ok, context}
      end
    end
  end

  # The machine block that names these agents.
  #
  # Empty when no block does, which is the failure the second `then_` reports:
  # a load figure the main agent cannot attach to anything is a number in a
  # report.
  defp machine_carrying(report, agents) do
    report
    |> section("machine:")
    |> String.split(~r/\n(?=  \S)/)
    |> Enum.find("", fn block -> Enum.all?(agents, &String.contains?(block, &1.id)) end)
  end

  # One labelled section of the report, up to the next one.
  defp section(report, label) do
    report
    |> String.split(~r/^(?=\w+:)/m)
    |> Enum.find("", &String.starts_with?(&1, label))
  end
end
