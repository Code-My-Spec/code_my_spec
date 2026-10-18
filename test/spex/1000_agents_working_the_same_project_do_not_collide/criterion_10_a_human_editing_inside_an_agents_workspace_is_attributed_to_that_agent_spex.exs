defmodule CodeMySpecSpex.Story1000.Criterion741Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 741 — A human editing inside an agent's workspace is attributed to that agent.

  Rule: Only work in an agent's workspace is tracked.

  The other side of criterion 740. There, an edit in an unserved copy is nobody's
  and must not be recorded. Here, an edit in a served copy is *that agent's*, even
  though no agent made it — because the agent is the working copy, not the
  process. An operator fixing a typo by hand has changed what that checkout
  contains, and its file state has to describe the tree as it now is.

  Attributing by working copy rather than by author is what makes that work. The
  alternative — tracking only edits an agent's own tools made — would leave the
  agent's file state describing a tree that no longer exists, and its analyzers
  reporting on code that is not there.

  A hand edit fires **no hook**. Nobody called Write, so no PostToolUse records
  it, and any spec that posts one to stand in for the operator is asserting
  against an agent's edit wearing an operator's name. The only thing that sees a
  hand edit is the harness watching the working copy — so the channel is the
  `when_`, and the agent's files page is where the consequence has to show up.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint
  @path "lib/typo_fixed_by_hand.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The working copy is the unit, not the author", criterion: 10 do
    scenario "A human editing inside an agent's workspace is attributed to that agent" do
      given_ :synced_context_component
      given_ :context_implementation_task_started

      given_ "an agent is serving a working copy", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "the operator edits a file in it by hand", context do
        # Straight into the working copy. No tool call, so no PostToolUse — that
        # absence is the premise, not an omission.
        #
        # Red until da2af26: a local stat reports whole-second mtimes, so an edit
        # made in the same second the task started is not "changed since" it.
        #
        # What a hand edit does produce:
        # the harness notices the tree changed and says so. That is the only
        # report the operator's edit generates.
        HarnessHooks.write_file(
          context,
          @path,
          "defmodule TypoFixedByHand do\n  @moduledoc false\nend\n"
        )

        {:ok, context}
      end

      then_ "the change is recorded against that agent", context do
        {:ok, _files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert html =~ "typo_fixed_by_hand.ex",
               "an edit made by hand inside a served working copy was not recorded against " <>
                 "the agent serving it. The agent's file state now describes a tree that no " <>
                 "longer exists, and its analyzers will report on code that is not there."

        {:ok, context}
      end
    end
  end
end
