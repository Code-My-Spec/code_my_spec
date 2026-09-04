defmodule CodeMySpecSpex.Story964.Criterion3085Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 3085 — An epic goes where the context already is.

  Rule: The main agent chooses whether an epic goes to a working copy that
  already exists or to a new one.

  This was a resolved red card (`1bb83d81`) that no rule ever carried. John
  answered it on 2026-08-25: *"Basically the agent decides. If an existing
  working copy and agent is appropriate — for example I've had you doing all the
  harness work — it gets assigned there, or a fresh one at the agent's
  discretion."*

  So neither "always mint" nor "always reuse". Continuity of context is the
  reason to reuse, and it is a real one: the copy that has been doing the
  harness work knows the harness. Sending its next epic somewhere else throws
  that away and pays for a fresh checkout to relearn it.

  ## The premise has to be a copy that is not the main one

  A first draft of this asserted that a second epic landed on the copy carrying
  the first, and it **passed** — on a project with one checkout, "where the
  context is" and "the main checkout" are the same place, so the assertion was
  satisfied by an implementation that does not choose anything.
  `EpicDispatch.destination/1` answers `WorkingCopies.main(scope)` for every
  epic on every project.

  So the copy carrying the work is deliberately a second one, reached through
  `assign_epic_to_working_copy` — the tool that exists precisely because
  placement is its own act (criterion 2930). Now the two answers differ, and the
  criterion can tell them apart.

  ## Why this is not criterion 2936

  2936 asserts the *permission* — a copy may hold more than one epic — and
  deliberately does not pin which copy an epic lands on. This asserts the
  *choice*. Same mechanism, seen as a constraint and as a behaviour.

  ## Red on purpose

  There is no choosing. Every epic goes to the main checkout regardless of what
  any copy is carrying.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The main agent chooses whether an epic goes to a working copy that already exists or to a new one" do
    scenario "An epic goes where the context already is" do
      given_ :synced_context_component

      given_ "a second working copy already carrying related work", context do
        # Not the main checkout — see the moduledoc. On a one-copy project this
        # criterion cannot fail.
        copy = join_working_copy(context, "/tmp/spex_3085_harness_work", "the harness work copy")

        first = EpicHelpers.propose(context, "Harness work, part one", stories: 1)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: first, working_copy_id: copy.working_copy_id},
            frame
          )

        {:ok, Map.put(context, :carrying, copy.working_copy_id)}
      end

      when_ "I approve an epic that belongs with it", context do
        EpicHelpers.dispatch_one(context, "Harness work, part two", stories: 1)

        {:ok, _live, html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the main agent places it on that copy rather than minting a new one", context do
        assert context.html =~ ~s(data-working-copy-id="#{context.carrying}"),
               "the second epic went somewhere other than the copy already doing " <>
                 "this work — every epic goes to the main checkout, whatever any " <>
                 "copy is carrying. Reuse is what makes the second epic cheaper than " <>
                 "the first: the copy that has been doing the harness work knows the " <>
                 "harness."

        {:ok, context}
      end
    end
  end
end
