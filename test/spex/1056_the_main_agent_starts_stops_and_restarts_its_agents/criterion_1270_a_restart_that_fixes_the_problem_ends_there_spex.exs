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

  The fault was an agent that stopped answering; it worked when the agent spoke
  again. Asserted by restarting a second time for the same reason after it has
  recovered and finding it allowed — which is exactly what 3292 forbids while
  the agent stays silent, and is the observable difference between the two.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  @reason "it stopped answering after its last turn"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A remedy that worked does not count against the next one", criterion: 1270 do
    scenario "an agent is restarted, works again, and the fault recurs later" do
      given_ "an agent restarted three times, working again after each", context do
        reply = join_working_copy(context, "/tmp/spex-3302", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        # The provider these agents run on — `running_agent/2` defaults to zai.
        # `Agents.restart_agent/2`
        # resolves one before it attempts anything — deliberately, so a restart
        # fails here rather than minutes later on the agent's first model call.
        {:ok, _integration} = CodeMySpecSpex.Fixtures.connect_provider(scope, :zai)

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3302"
          )

        frame = %Frame{assigns: %{current_scope: scope}}

        # The machine is answering throughout: this is an agent-level fault, the
        # only kind a restart reaches.
        CodeMySpecSpex.Fixtures.record_machine_tools(scope, ["Read", "Write", "Bash"])

        for recurrence <- 1..3 do
          response =
            ToolLibrary.run(
              "restart_agent",
              %{agent_id: agent.id, reason: @reason},
              Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
            )

          assert match?({:ok, _}, response), inspect(response)

          # It worked: the agent spoke again. That is what closes the reason, and
          # the difference between this scenario and 3292's.
          :ok =
            CodeMySpecSpex.Fixtures.agent_said(
              scope,
              agent,
              "back after restart #{recurrence}"
            )
        end

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the same fault appears again and the main agent restarts it", context do
        # Quiet again, three recoveries later.
        :ok =
          CodeMySpecSpex.Fixtures.age_agent_messages(context.scope, context.agent, 3 * 60 * 60)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "restart_agent",
            %{agent_id: context.agent.id, reason: @reason},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the restart is allowed, because every earlier one worked", context do
        assert match?({:ok, _}, context.response),
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
