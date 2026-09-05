defmodule CodeMySpecSpex.Story895.Criterion2398Spex do
  @moduledoc """
  Story 895 — Stories are assigned to a working copy.
  Criterion 2398 — Having assignments does not hide the unassigned backlog.

  Rule: A working copy gets its assigned stories and every unassigned story.

  The direction of the default, and the half that is easy to get backwards.
  John: *"if a harness is assigned stories, it should get its assigned stories
  and all unassigned stories. Unassigned stories should surface to all working
  copies."*

  So assignment narrows what a working copy is **refused** for and never narrows
  the backlog it can see. A project with no assignments anywhere behaves exactly
  as it did before the axis existed, which is what makes it shippable empty.

  It also fails the safe way. If unassigned work were invisible until claimed,
  the first consequence would be a project where nobody is offered anything, and
  the second an agent that stops with a full backlog and a clean menu. The worst
  case of visible-by-default is the behaviour we already have.

  ## Why the second assertion carries the criterion

  The first is nearly free — a checkout being offered its own story is what any
  implementation of assignment does. The one that can fail is the unassigned
  story, because the obvious way to write the filter is
  `working_copy_id == mine`, which is correct for the assigned case and drops
  the entire backlog.

  ## Why `list_requirements` and not the printed menu

  `get_next_requirement` renders one orchestration group at a time, so two
  stories are legitimately not both *printed* even when both are available —
  an assertion on that text would pass or fail on rendering order. The criterion
  is about which stories this checkout is working from at all, and
  `list_requirements` is the agent-facing view of exactly that set. A story
  missing from it can never be offered, on this call or any later one.

  Surface: the epic tools (placement, which is how a story gets assigned),
  `get_next_requirement` (the act the criterion names) and `list_requirements`
  (the set it selects from).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

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
    scenario "Having assignments does not hide the unassigned backlog" do
      given_ :synced_context_component

      given_ "a story assigned to this working copy", context do
        epic = EpicHelpers.propose(context, "Work that is ours", stories: 1)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic, working_copy_id: context.scope.active_working_copy_id},
            frame
          )

        {:ok, Map.put(context, :mine, "Work that is ours — part 1")}
      end

      given_ "a story assigned to no working copy", context do
        # Proposed and never placed. That is the ordinary state of the backlog
        # rather than a special case — assignment is something somebody does
        # later, and most stories never have it done to them at all.
        EpicHelpers.propose(context, "Work nobody has claimed", stories: 1)

        {:ok, Map.put(context, :unclaimed, "Work nobody has claimed — part 1")}
      end

      when_ "the agent asks for its next work", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _next, _frame} = GetNextRequirement.execute(%{}, frame)

        # The set that call selects out of. `limit` well above the story count
        # on purpose: a truncated list would drop a story for a reason that has
        # nothing to do with assignment, and the criterion would fail — or pass
        # — for the wrong reason.
        {:reply, listing, _frame} =
          ListRequirements.execute(%{entity_type: "story", limit: 500}, frame)

        {:ok, Map.put(context, :visible, inspect(listing))}
      end

      then_ "the story assigned here is among the work this copy is drawing from",
            context do
        assert context.visible =~ context.mine,
               "a checkout was not offered a story assigned to it, which is the one " <>
                 "thing assignment has to do."

        {:ok, context}
      end

      then_ "and so is the story assigned to nobody", context do
        assert context.visible =~ context.unclaimed,
               "having assignments hid the unassigned backlog. Unassigned work belongs " <>
                 "to every checkout rather than to none — the filter is " <>
                 "assigned-here-or-unassigned, and the natural mistake is to write " <>
                 "`working_copy_id == mine`, which is right for the story above and " <>
                 "drops the whole backlog with it."

        {:ok, context}
      end
    end
  end
end
