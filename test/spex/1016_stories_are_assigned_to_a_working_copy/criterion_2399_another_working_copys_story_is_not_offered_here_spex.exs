defmodule CodeMySpecSpex.Story895.Criterion2399Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2399 — Another working copy's story is not offered here.

  Rule: A working copy gets its assigned stories and every unassigned story.

  The half the latch could not do, and the reason this story came off the park.

  895 was parked on 2026-08-18 to see whether `specs_ready` made a new axis
  unnecessary. For **blocking** it largely did: the latch is earned by a green
  run, so a red spex on an unlatched story is advisory wherever it lives, and
  work in flight in another checkout stopped blocking anybody. What the latch
  has no opinion about is **selection**. `get_next_requirement` had no notion of
  a working copy at all, so three agents staffed on a copy and handed an epic
  pulled whatever the project offered next — which was, reliably, somebody
  else's work.

  That is the fresh incident the park asked for, seen on 2026-09-05: an epic was
  placed on a copy, its agents were started, and the first thing they were
  offered had nothing to do with it.

  ## Why the second assertion is not decoration

  A filter that offers nothing at all satisfies "that story is not offered".
  The unassigned story is the control: it proves the checkout is still being
  offered work, so the absence above is assignment doing its job rather than the
  graph being empty. Without it this criterion passes on a filter that drops
  everything.

  Surface: the epic tools (placement, which is how a story gets assigned),
  `get_next_requirement` (the act) and `list_requirements` (the set it selects
  from — see criterion 2398 on why the printed menu is the wrong thing to
  assert against).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpecSpex.EpicHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A working copy gets its assigned stories and every unassigned story" do
    scenario "Another working copy's story is not offered here" do
      given_ :synced_context_component

      given_ "a story assigned to another working copy", context do
        # A real second checkout, joined through the harness channel. Not the
        # one this agent is standing in, which is the whole premise: on a
        # one-copy project "somebody else's story" cannot exist and the
        # criterion could not fail.
        theirs =
          join_working_copy(context, "/tmp/spex_2399_their_copy", "the other checkout")

        epic = EpicHelpers.propose(context, "Work that is theirs", stories: 1)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic, working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, Map.put(context, :theirs, "Work that is theirs — part 1")}
      end

      given_ "a story assigned to no working copy", context do
        EpicHelpers.propose(context, "Work nobody has claimed", stories: 1)

        {:ok, Map.put(context, :unclaimed, "Work nobody has claimed — part 1")}
      end

      when_ "the agent asks for its next work", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

        {:reply, listing, _frame} =
          ListRequirements.execute(%{entity_type: "story", limit: 500}, frame)

        {:ok, Map.put(context, :visible, inspect(listing))}
      end

      then_ "that story is not offered", context do
        refute context.visible =~ context.theirs,
               "this checkout was offered a story assigned to a different one. Three " <>
                 "agents staffed on a copy and handed an epic will pull whatever the " <>
                 "project offers next, which is how an epic gets placed and then " <>
                 "worked on everywhere except where it was placed."

        {:ok, context}
      end

      then_ "and a story assigned to no working copy is still offered", context do
        assert context.visible =~ context.unclaimed,
               "nothing is offered here at all, so the absence above says nothing " <>
                 "about assignment — a filter that drops every story satisfies it just " <>
                 "as well as the right one."

        {:ok, context}
      end
    end
  end
end
