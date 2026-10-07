defmodule CodeMySpecSpex.Story1016.Criterion2399Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 2399 — Another working copy's story is not offered here.

  Rule: Assignment preserves visibility of assigned and unassigned backlog
  stories; story 802 limits execution to the working copy's single active story.

  The routing half of the assignment axis, and the one the story was unparked
  over. John: *"get_next_requirement has no notion of a working copy, so three
  agents on a copy given the war epic pull whatever the project offers next."*
  This criterion is exactly that routing: another copy's story is theirs, and
  the checkout looking at it is offered none of it.

  ## Three stories, because two cannot express it

  B alone would show that somebody else's story is withheld. C alone would show
  that an unassigned story is withheld. Only with both is the claim complete,
  because the interesting case is what an agent reaches for when its own story
  has nothing for it: B and C are both sitting there and neither is a
  substitute. C is the trap — it is unassigned, so nothing on the project says
  it is spoken for, and a next-actionable that falls back to the shared backlog
  hands it over. That fallback is precisely the "pull whatever the project
  offers next" behaviour this criterion rules out.

  ## Why C must stay discoverable

  Withholding C as *work* and hiding C from the *backlog* are different things,
  and only the first is correct. Criterion 2398 states the general rule and
  this scenario re-states it for the third story, so a next-actionable narrowed
  by hiding stories instead of by excluding them is caught here rather than
  passing quietly: a backlog pruned to whatever routing currently allows is a
  backlog the agent cannot reason about.

  Surface: the epic tools (placement), the backlog tool, and
  `get_next_requirement`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpec.McpServers.Stories.Tools.ListStoryTitles
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import CodeMySpecSpex.WorkingCopyHelpers, only: [join_working_copy: 3]

  setup :register_log_in_setup_account
  setup :setup_active_project

  @their_label "the other checkout"
  @epic_name "Work that is theirs"

  spex "Another copy's story is not offered here", criterion: 897 do
    scenario "Another working copy's story is not offered here" do
      given_ "story A is active in this working copy", context do
        {:ok, Slice.base(context)}
      end

      given_ "story B is assigned to another working copy", context do
        # B is its own story, built as the project builds one, so all three
        # stories in this scenario are separately addressable.
        b_story =
          StoryHelpers.create_and_link(context.scope, "Reservations",
            title: "Theirs to build",
            description: "Work that is the other checkout's",
            acceptance_criteria: ["It works"],
            priority: 0
          )

        theirs = join_working_copy(context, "/tmp/spex_2399_their_copy", @their_label)
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, created, _frame} =
          CreateEpic.execute(%{name: @epic_name, description: "Theirs to build"}, frame)

        {:reply, _assigned, _frame} =
          AssignStoryToEpic.execute(
            %{story_number: b_story.number, epic_name: @epic_name},
            frame
          )

        {:reply, _placed, _frame} =
          AssignEpicToWorkingCopy.execute(
            %{epic_id: epic_id(created), working_copy_id: theirs.working_copy_id},
            frame
          )

        {:ok, Map.merge(context, %{b_story: b_story, theirs: theirs})}
      end

      given_ "story C is unassigned", context do
        # A third story in the shared backlog, and the one that catches a
        # fallback to it. Its module is its own, so its components are
        # distinct from A's and B's.
        {:ok, Slice.waiting(context, module: "Unclaimed", assigned: false)}
      end

      when_ "the agent requests next actionable work", context do
        {:ok, Map.put(context, :answer, Slice.next(context))}
      end

      then_ "only eligible work in A is offered", context do
        assert context.answer =~ "# Story #{context.story.number}:",
               "the copy's own active story is not what it is offered. Got:\n" <>
                 context.answer

        assert context.answer =~ "### ReadyForQa",
               "nothing from A is offered, so 'only A' would pass on an empty answer. " <>
                 "The anchor is the work A actually still owes: without it, an offer " <>
                 "naming nothing would satisfy every refute below. Got:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and neither B nor C is offered as replacement work", context do
        refute context.answer =~ "# Story #{context.b_story.number}:",
               "a story assigned to another checkout was offered here. That is the " <>
                 "incident this story was unparked for: three agents on one copy pull " <>
                 "whatever the project offers next, because next-actionable has no " <>
                 "notion of a working copy. Got:\n#{context.answer}"

        refute context.answer =~ "# Story #{context.waiting.number}:",
               "an unassigned story was handed over as replacement work. C is the trap " <>
                 "in this scenario: nothing on the project says it is spoken for, so a " <>
                 "fallback to the shared backlog picks it up — and the copy's active " <>
                 "story stops meaning anything. Got:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and C remains discoverable in the backlog", context do
        backlog = Slice.call(context, ListStoryTitles, %{})

        assert backlog =~ context.waiting.title,
               "C was excluded by being hidden rather than by being withheld. The " <>
                 "backlog is what an agent reasons about; pruning it to whatever " <>
                 "routing currently allows is a different change from the one this " <>
                 "criterion makes, and a worse one. Got:\n#{backlog}"

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
