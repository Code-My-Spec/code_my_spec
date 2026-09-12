defmodule CodeMySpecSpex.Story1059.Criterion3317Spex do
  @moduledoc """
  Story 1059 — The main agent looks in on its agents on a cadence.
  Criterion 3317 — The main agent comes back round on its own.

  The first spex on this story, so it chooses the surface the rest inherit:
  `CodeMySpec.MainAgent.Cadence`, one per project, woken on an interval.

  ## Pull, because push is exactly what a broken agent has lost

  The story's own note is the argument. One outage was visible only because the
  affected agent could still call `send_message`; had it lost that too, it would
  have sat silent indefinitely and nothing would have asked. Every delivery
  mechanism this system has depends on the thing in trouble still working well
  enough to say so.

  So the cadence is not a nicety on top of story 1053's delivery. It is the only
  mechanism that survives the failure it exists to catch, and criterion 3319 is
  that case stated directly.

  ## Driven by a tick, not by waiting

  The scenario calls the cadence's own tick. Waiting for a timer would make the
  spex slow and — worse — make it pass by accident on a machine that happened to
  be loaded enough for the timer to fire twice. What the criterion claims is
  that the wake-up needs no event to prompt it, and the tick is that wake-up.

  Nothing is pushed in this scenario, deliberately: no question, no turn, no
  file change. If the main agent hears anything at all, it is because it came
  back round.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The check-in happens because the clock came round" do
    scenario "nothing at all has happened since the last one" do
      given_ "a main agent and a coding agent, and nothing pushed to either",
             context do
        reply = join_working_copy(context, "/tmp/spex-3317", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        main = Fixtures.running_agent(scope, role: "main", working_copy: "/tmp/spex-3317")
        coding = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-3317")

        # Deliberately quiet. No question, no turn, no file change — so anything
        # the main agent hears afterwards, it went and got.
        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:main, main)
         |> Map.put(:coding, coding)}
      end

      when_ "the cadence comes round", context do
        :ok = Fixtures.cadence_tick(context.scope)

        {:ok, context}
      end

      then_ "the main agent has looked at its agents", context do
        {:ok, _live, html} =
          live(context.conn, Fixtures.agent_conversation_path(context.scope, context.main))

        assert html =~ ~r/check-?in/i,
               """
               The cadence came round and the main agent heard nothing.

               Every delivery mechanism this system has depends on the thing in
               trouble still working well enough to say so. One outage was
               visible only because the affected agent could still call
               `send_message`; had it lost that too it would have sat silent
               indefinitely, and nothing would have asked.

               The cadence is the only mechanism that survives the failure it
               exists to catch, which is why it is a pull and not one more
               push.

               transcript:
               #{html}
               """

        assert html =~ context.coding.id,
               """
               The check-in happened and does not say what it found.

               A wake-up with no digest is a main agent that has to go and
               assemble one — criterion 3332 — and at that point the cadence has
               cost a turn and bought nothing.

               transcript:
               #{html}
               """

        {:ok, context}
      end
    end
  end
end
