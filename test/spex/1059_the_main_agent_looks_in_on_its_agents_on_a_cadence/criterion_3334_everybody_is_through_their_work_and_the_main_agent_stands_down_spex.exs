defmodule CodeMySpecSpex.Story1059.Criterion3334Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3334 — Everybody is through their work and the main agent stands
  down.

  Rule: a loop with nothing left to do ends.

  The cadence exists to catch a problem while work is in flight. With the work
  finished there is nothing in flight, and a timer that keeps firing is a model
  call every twenty minutes, indefinitely, to look at a fleet that has nothing
  to look at — on somebody's bill.

  It is also the shape that makes people distrust the whole mechanism. A loop
  that cannot stop is one you supervise, and supervising it is exactly the work
  the main agent was supposed to remove.

  ## Tapping out is the act, not the timer running out

  `tap_out` is the documented way an agent asks to leave a loop, and the
  criterion hangs the cadence off it rather than off "the graph is empty" — so
  the decision stays the main agent's judgement about its own project rather
  than a rule computed from a count that could be temporarily zero.

  ## Asserted as the cadence stopping, not as one quiet tick

  Criterion 3320 already covers a check-in that finds nothing and says nothing.
  This is a stronger claim: the wake-ups stop happening at all, which is why the
  scenario ticks *after* the tap-out and requires that nothing came of it.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The cadence ends when the work does" do
    scenario "every agent has finished and nothing is outstanding" do
      given_ "a main agent with a running cadence and no work left", context do
        reply = join_working_copy(context, "/tmp/spex-3334", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main =
          Fixtures.running_agent(scope,
            role: "main",
            working_copy: "/tmp/spex-3334",
            continuous: true
          )

        :ok = Fixtures.set_cadence_interval(scope, 20 * 60)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:main, main)}
      end

      when_ "the main agent taps out", context do
        frame = %Frame{
          assigns: %{current_scope: context.scope, agent_id: context.main.id}
        }

        {:reply, tapped, _frame} = TapOut.execute(%{}, frame)

        refute tapped.isError,
               "the tap-out had to actually happen for this to mean anything:\n" <>
                 inspect(tapped)

        {:ok, context}
      end

      then_ "the cadence stops", context do
        refute Fixtures.cadence_running?(context.scope),
               """
               The cadence is still running after the main agent stood down.

               A model call every twenty minutes, indefinitely, to look at a
               fleet with nothing to look at — on somebody's bill. And a loop
               that cannot stop is one you end up supervising, which is exactly
               the work the main agent was supposed to remove.
               """

        {:ok, context}
      end

      then_ "and it is not woken on a timer with nothing to look at", context do
        before = Fixtures.messages_to_agent(context.scope, context.main.id)

        :ok = Fixtures.cadence_tick(context.scope)

        assert Fixtures.messages_to_agent(context.scope, context.main.id) == before,
               """
               A tick after the tap-out still woke the main agent.

               Criterion 3320 covers a check-in that finds nothing and says
               nothing; this is the stronger claim that the wake-ups stop
               happening at all. A cadence that merely goes quiet still costs a
               turn every interval, and the agent it wakes has already said it
               is finished.
               """

        {:ok, context}
      end
    end
  end
end
