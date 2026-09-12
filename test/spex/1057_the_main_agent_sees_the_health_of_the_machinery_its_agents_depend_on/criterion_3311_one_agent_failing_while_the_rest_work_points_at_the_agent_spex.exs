defmodule CodeMySpecSpex.Story1057.Criterion3311Spex do
  @moduledoc """
  Story 1057 — The main agent sees the health of the machinery its agents
  depend on.
  Criterion 3311 — One agent failing while the rest work points at the agent.

  Rule: a fault nothing else shares belongs to the one thing that has it.

  3310's mirror, and the pair only works because both exist. A report that
  blamed the machinery whenever anything went wrong would satisfy 3310 perfectly
  and be useless — it would send the main agent to raise an issue about a
  harness that is fine, while the one agent that actually needs restarting sits
  there.

  That failure is quieter than 3310's and lasts longer. Nobody restarts the
  agent, because the report says the problem is elsewhere; nobody fixes the
  machinery, because there is nothing wrong with it; and the issue raised about
  it is dismissed, which teaches everybody to dismiss the next one.

  ## Read from the tools section, not the whole report

  Both assertions here first ran against the whole report and both passed with
  the attribution blinded to "always blame the machine" — the machine section
  lists every agent on the box (criterion 3324 requires it to), so "the broken
  agent is named" was true whoever was blamed, and the machinery's fault was
  phrased in words the refutation did not happen to match.

  The tools line is the one that attributes the fault, so it is the one this
  criterion reads.

  ## Two checkouts, because that is what makes the comparison possible

  One copy's machine reports no tools, another's reports plenty. A report that
  reads only the asking copy would see a single broken machine and have nothing
  to compare it with — which is how "one agent" and "every agent" become the
  same reading.
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

  spex "A lone failure is placed with the agent that has it" do
    scenario "one checkout's machine reports no tools and another's is fine" do
      given_ "one agent that cannot call tools and two that can", context do
        broken_reply = join_working_copy(context, "/tmp/spex-3311-broken", "the broken checkout")
        broken_scope = %{context.scope | active_working_copy_id: broken_reply.working_copy_id}

        broken =
          Fixtures.running_agent(broken_scope,
            role: "coding",
            working_copy: "/tmp/spex-3311-broken"
          )

        Fixtures.record_machine_tools(broken_scope, [])

        well_reply = join_working_copy(context, "/tmp/spex-3311-well", "the working checkout")
        well_scope = %{context.scope | active_working_copy_id: well_reply.working_copy_id}

        for role <- ["qa", "product"] do
          Fixtures.running_agent(well_scope, role: role, working_copy: "/tmp/spex-3311-well")
        end

        Fixtures.record_machine_tools(well_scope, ["Read", "Write", "Bash"])

        {:ok,
         context
         |> Map.put(:scope, well_scope)
         |> Map.put(:broken, broken)}
      end

      when_ "the main agent looks at the machinery", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = CheckMachinery.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :report, response_text(response))}
      end

      then_ "the machinery is shown as working", context do
        attribution = section(context.report, "tools:")

        refute attribution =~ ~r/faulty|broken|down/i,
               """
               One agent in trouble is being reported as a machinery fault.

               This is quieter than 3310's failure and lasts longer. Nobody
               restarts the agent, because the report says the problem is
               elsewhere; nobody fixes the machinery, because nothing is wrong
               with it; and the issue raised about it gets dismissed, which
               teaches everybody to dismiss the next one.

               tools section:
               #{attribution}
               """

        {:ok, context}
      end

      then_ "and the fault is placed with that agent", context do
        attribution = section(context.report, "tools:")

        assert attribution =~ context.broken.id,
               """
               The report does not say which agent is the one in trouble.

               "Not the machinery" is only half an answer. The main agent's next
               move is a restart and it needs to know what to restart — a report
               that rules the machine out and names nothing leaves it exactly
               where it started, with one more thing ruled out and nothing to
               do.

               tools section:
               #{attribution}
               """

        {:ok, context}
      end
    end
  end

  # One labelled section of the report, up to the next one.
  #
  # Asserting against the whole report matches whichever section happens to use
  # a word, which is how both of this criterion's assertions passed with the
  # attribution deliberately blinded out — the machine section lists every agent
  # on the box, so "the broken agent is named" was true no matter who was
  # blamed.
  defp section(report, label) do
    report
    |> String.split(~r/^(?=\w+:)/m)
    |> Enum.find("", &String.starts_with?(&1, label))
  end
end
