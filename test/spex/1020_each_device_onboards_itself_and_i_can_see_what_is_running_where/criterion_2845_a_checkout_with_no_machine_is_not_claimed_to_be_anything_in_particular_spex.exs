defmodule CodeMySpecSpex.Story1020.Criterion2845Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2845 — A checkout with no machine is not claimed to be anything in
  particular.

  Rule: A device that goes leaves its working copies behind, orphaned rather
  than deleted — and an orphan is indistinguishable from a copy that never
  reported one.

  Two histories, one state. A copy onboarded before devices existed never
  reported a machine; a copy whose machine was destroyed, or whose owner simply
  uninstalled CMS, had one and lost it. From the row they are identical, and
  they should be — `device_id` nullifies either way.

  What follows is that the page may claim neither. "Waiting for its machine"
  invents a future that may never come; "orphaned" invents a past that may not
  have happened. Both are the same error as `Liveness` calling a `:starting`
  agent "Running": asserting more than the evidence carries, in whichever
  direction reads better.

  The copy stays listed. Leaving it out would say "that checkout is gone", when
  all that is true is that nothing has told us where it is.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A copy with no machine is described honestly or not at all" do
    scenario "A checkout with no machine is not claimed to be anything in particular" do
      given_ "a checkout whose machine is not known — never reported, or gone with the box",
             context do
        # No `device_id:` at all, which is exactly what a harness built before
        # devices sends. The other history — a machine that was destroyed —
        # nullifies to the same state, which is the point of the rule.
        copy = join_working_copy(context, "/tmp/spex-1020-orphan", "an orphaned checkout")

        {:ok, Map.put(context, :copy, copy)}
      end

      when_ "I look at it", context do
        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        row =
          live
          |> element(
            "[data-test='working-copy'][data-working-copy-id='#{context.copy.working_copy_id}']"
          )
          |> render()

        {:ok, context |> Map.put(:live, live) |> Map.put(:row, row)}
      end

      then_ "it says it has no machine, and that it may be orphaned", context do
        assert context.row =~ ~r/no machine|machine (is )?not known|orphan/i,
               "the copy has no machine and the row says nothing about that. " <>
                 "Silence reads as 'this is fine', which is the one thing that " <>
                 "is not established. Got: #{context.row}"

        {:ok, context}
      end

      then_ "and it does not claim the machine is still coming, nor that the checkout is dead",
            context do
        refute context.row =~ ~r/waiting for|pending|will appear|connecting/i,
               "the row promises a machine is on its way. Nothing has said that, " <>
                 "and for a copy whose box was destroyed it is false forever."

        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.copy.working_copy_id}']"
               ),
               "the copy was left out of the list. That reads as 'that checkout " <>
                 "is gone', when all that is true is that nothing has told us where it is."

        {:ok, context}
      end
    end
  end
end
