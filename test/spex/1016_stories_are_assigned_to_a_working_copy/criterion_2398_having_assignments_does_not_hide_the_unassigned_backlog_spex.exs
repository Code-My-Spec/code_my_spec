defmodule CodeMySpecSpex.Story1016.Criterion2398Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2398 — Having assignments does not hide the unassigned backlog.

  Rule: Assignment preserves visibility of assigned and unassigned backlog
  stories; story 802 limits execution to the working copy's single active story.

  Assignment narrows what a copy is *refused* for. It must not narrow the
  backlog it can *see*. John: *"if a harness is assigned stories, it should get
  its assigned stories and all unassigned stories. Unassigned stories should
  surface to all working copies."* Loud everywhere, blocking in one place.

  ## Why visibility and execution are asserted in one scenario

  They are the two halves of the same claim and they pull in opposite
  directions, so a scenario that proved only one of them would pass on the
  failure mode the other describes. Discovery staying wide is what keeps a
  backlog workable: an agent that cannot see the unassigned pile cannot tell a
  quiet project from an empty one. Offering staying narrow is what makes the
  active story mean anything at all — if next-actionable quietly offered the
  unassigned story too, the team would be working two stories and story 802's
  single active story would be a label rather than a binding.

  So both are asserted here. Read together they say: B is visible and B is not
  offered, which is exactly the distinction the criterion is named for.

  ## Why "B is unassigned" needs a second working copy

  The same reason criterion 2396 gives. On a project where nobody has assigned
  anything, "unassigned" is true of every story and the system says so about
  none of them; `waiting/2`'s `assigned: false` keeps B genuinely in the shared
  backlog while another checkout holds other work, which is the premise.

  Surface: the epic tools (placement), the backlog tool and
  `get_next_requirement` (what the agent sees), and the working copy's own
  active story.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy: 3]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @their_label "the other checkout"
  @epic_name "Work that is theirs"

  spex "Assignment never hides the backlog it was assigned beside", criterion: 896 do
    scenario "Having assignments does not hide the unassigned backlog" do
      given_ "story A is assigned and active in this working copy", context do
        # `Slice.base/1` creates ExampleContext's story and makes it this
        # copy's team's active story, so A is both assigned here and the one
        # story execution is limited to.
        {:ok, Slice.base(context)}
      end

      given_ "and the work here is not the only assignment on the project", context do
        # A second checkout holding other work, so "unassigned" is a fact about
        # B rather than about every story in the project.
        theirs = join_working_copy(context, "/tmp/spex_2398_their_copy", @their_label)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, created, _frame} =
          CreateEpic.execute(%{name: @epic_name, description: "Theirs to build"}, frame)

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id(created), working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, context}
      end

      given_ "and story B is unassigned", context do
        # `assigned: false` is the whole point: B stays in the shared backlog.
        {:ok, Slice.waiting(context, assigned: false)}
      end

      when_ "the agent browses its available backlog", context do
        {:ok, Map.put(context, :backlog, Slice.call(context, ListStoryTitles, %{}))}
      end

      then_ "both stories remain discoverable", context do
        assert context.backlog =~ context.story.title,
               "the story this copy is working has vanished from its own backlog. " <>
                 "Assignment must never cost an agent sight of the work it is on. " <>
                 "Got:\n#{context.backlog}"

        assert context.backlog =~ context.waiting.title,
               "an unassigned story is missing from the backlog. Hiding the unassigned " <>
                 "pile is how a backlog stops being a backlog: the agent cannot tell a " <>
                 "project with nothing to do from one whose work it is no longer " <>
                 "allowed to see. Got:\n#{context.backlog}"

        {:ok, context}
      end

      when_ "the agent requests next actionable work", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "only eligible work in the active story A is offered", context do
        assert context.answer =~ "# Story #{context.story.number}:",
               "the copy's own active story is not what it is offered. Got:\n" <>
                 context.answer

        assert context.answer =~ "### ReadyForQa",
               "nothing from A is offered, so 'only A' would pass on an empty answer. " <>
                 "The anchor is the work A actually still owes: without it, an offer " <>
                 "naming nothing would satisfy every refute below. Got:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and B is not implicitly activated", context do
        refute context.answer =~ "# Story #{context.waiting.number}:",
               "next-actionable handed the agent a second story. Story 802 limits " <>
                 "execution to the working copy's single active story, and discovery is " <>
                 "not permission to work: seeing B in the backlog is not being told to " <>
                 "build it. Got:\n#{context.answer}"

        refute context.answer =~ "### ComponentSpec",
               "an unassigned story's requirements were offered as replacement work " <>
                 "while the team is still on its own story. `Waiting`'s graph is " <>
                 "distinct from A's, so a component-level offer here is B's work, not " <>
                 "A's. Got:\n#{context.answer}"

        {:ok, context}
      end
    end
  end

  # The epic id out of `create_epic`'s own reply, as `waiting/2` reads it back.
  defp epic_id(response) do
    response
    |> response_text()
    |> then(&Regex.run(~r/ID: ([^,]+)/, &1))
    |> epic_id_match(response)
  end

  defp epic_id_match([_, id], _response), do: id

  defp epic_id_match(nil, response),
    do: flunk("could not read an epic id out of: #{inspect(response)}")
end
