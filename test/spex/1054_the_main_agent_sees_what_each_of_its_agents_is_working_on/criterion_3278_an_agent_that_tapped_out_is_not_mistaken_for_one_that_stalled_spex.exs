defmodule CodeMySpecSpex.Story1054.Criterion3278Spex do
  @moduledoc """
  Story 1054 — The main agent sees what each of its agents is working on.
  Criterion 3278 — An agent that tapped out is not mistaken for one that
  stalled.

  Rule: an agent that asked to stop is doing what it was told to do.

  The second of the three quiet-with-a-cause criteria, and the one where reading
  it wrongly undoes a decision somebody already made. Tapping out is the
  documented escape from the loop: the agent asks to leave, is told to stop and
  wait, and waiting is then the correct behaviour. A view that reads that
  silence as a fault sends the main agent to restart an agent that is obeying
  its last instruction — which puts it straight back in the loop it asked to
  leave, and the request it raised is still sitting there for a human.

  Distinct from 3277 in who has to act. There the main agent can answer the
  question itself. Here the decision belongs to a person, and the right move for
  the main agent is nothing at all — so the view has to say enough that "nothing
  at all" is legible as a choice rather than as an oversight.

  Driven through `tap_out` as an agent calls it, which writes the pending
  permission request the stop decision already checks. Writing the row directly
  would test a shape nothing produces.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent waiting to be let out is not a fault" do
    scenario "an agent has asked to leave the loop and is waiting on a person" do
      given_ "an agent that tapped out and has been quiet since", context do
        reply = join_working_copy(context, "/tmp/spex-3278", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        agent =
          CodeMySpecSpex.Fixtures.running_agent(scope,
            role: "coding",
            working_copy: "/tmp/spex-3278",
            continuous: true
          )

        frame = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, tapped, _frame} = TapOut.execute(%{}, frame)

        refute tapped.isError,
               "the tap-out had to actually happen for this to mean anything:\n" <>
                 inspect(tapped)

        # Stopped and waiting, which is exactly what it was told to do.
        :ok = CodeMySpecSpex.Fixtures.age_agent_messages(scope, agent, 50 * 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:agent, agent)}
      end

      when_ "the main agent looks at that agent", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListAgentWork.execute(%{}, frame)

        refute response.isError, inspect(response)

        {:ok, Map.put(context, :view, response_text(response))}
      end

      then_ "the tap-out is shown and explains the silence", context do
        assert context.view =~ ~r/tap(ped)?[ _-]?out/i,
               """
               The agent's tap-out is nowhere in the view.

               It asked to leave the loop, was told to stop and wait, and is
               doing precisely that. Shown as fifty minutes of unexplained
               silence, the remedy the main agent reaches for is a restart —
               which puts it back in the loop it asked to leave, while the
               request it raised is still sitting there for a human.

               view:
               #{context.view}
               """

        refute context.view =~ ~r/\b(stalled|stuck|dead|not responding|fault)\b/i,
               """
               A tapped-out agent is being reported as broken.

               The decision is a person's and the right move for the main agent
               is nothing at all — so the view has to leave "nothing at all"
               legible as a choice rather than as something nobody got round to.

               view:
               #{context.view}
               """

        {:ok, context}
      end
    end
  end
end
