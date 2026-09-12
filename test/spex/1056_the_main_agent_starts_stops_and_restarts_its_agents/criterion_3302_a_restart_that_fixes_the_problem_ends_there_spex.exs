defmodule CodeMySpecSpex.Story1056.Criterion3302Spex do
  @moduledoc """
  Story 1056 — The main agent starts, stops and restarts its agents.
  Criterion 3302 — A restart that fixes the problem ends there.

  Rule: a reason that has been dealt with stops counting against the agent.

  The counterweight to 3292, and the criterion that keeps it from being a
  one-way ratchet. 3292 refuses a restart whose reason has already been tried
  and failed; without this, an agent that was successfully restarted three
  times over a week for three separate recurrences of the same fault would find
  itself refused on the fourth — punished for a history of remedies that all
  worked.

  That failure is quiet and slow. The refusal arrives with a sensible message
  about a fault already tried, nobody disputes it, and an agent that could have
  been fixed in seconds stays broken.

  So a restart that worked closes its reason, and the count 3292 keeps is a
  count of *unresolved* attempts rather than of attempts.

  ## What "worked" means, and why the scenario has to produce it

  The fault was the machine reporting no tools; it worked when the machine
  reports tools again. Asserted by restarting a second time for the same reason
  after the fault has cleared and finding it allowed — which is exactly what
  3292 forbids while the fault persists, and is the observable difference
  between the two criteria.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.RestartAgent
  alias Ecto.Adapters.SQL.Sandbox

  @reason "its tools stopped resolving after the harness reconnected"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A remedy that worked does not count against the next one" do
    scenario "an agent is restarted, works again, and the fault recurs later" do
      given_ "an agent restarted three times, working again after each", context do
        reply = join_working_copy(context, "/tmp/spex-3302", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3302"
          )

        frame = %Frame{assigns: %{current_scope: scope}}

        for _recurrence <- 1..3 do
          CodeMySpecSpex.Fixtures.record_machine_tools(scope, [])

          {:reply, response, _frame} =
            RestartAgent.execute(%{agent_id: agent.id, reason: @reason}, frame)

          refute response.isError, inspect(response)

          # It worked. The fault is gone until the next recurrence, which is the
          # difference between this scenario and 3292's.
          CodeMySpecSpex.Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])
        end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the same fault appears again and the main agent restarts it", context do
        CodeMySpecSpex.Fixtures.record_machine_tools(context.scope, [])

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          RestartAgent.execute(%{agent_id: context.agent.id, reason: @reason}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the restart is allowed, because every earlier one worked", context do
        refute context.response.isError,
               """
               An agent is being refused a restart because of a history of
               remedies that all worked.

               3292's refusal has to count unresolved attempts, not attempts. A
               fault that recurs three times and is fixed three times is an
               agent being looked after; counting those the same way as three
               failures makes the fourth recurrence permanent, and the refusal
               arrives with a sensible message nobody will dispute.

               reply:
               #{response_text(context.response)}
               """

        {:ok, context}
      end
    end
  end
end
