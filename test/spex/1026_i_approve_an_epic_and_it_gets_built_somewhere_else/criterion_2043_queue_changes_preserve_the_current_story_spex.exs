defmodule CodeMySpecSpex.Story1026.Criterion2043Spex do
  @moduledoc """
  Story 1026 — Queue changes preserve the story the team is working on.
  Adding an epic is a queue edit, independent of selecting the team's story.
  Both teammates read their current work through the real requirement tool.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.McpServers.Stories.Tools.AssignEpicToWorkingCopy
  alias CodeMySpec.McpServers.Stories.Tools.AssignStoryToEpic
  alias CodeMySpec.McpServers.Stories.Tools.CreateEpic
  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Editing a copy's queue preserves its team's current story", criterion: 2043 do
    scenario "Adding another epic leaves both teammates on their current story" do
      given_ "a team working on a story and an epic waiting to join its queue", context do
        context =
          context
          |> Slice.main_copy()
          |> Slice.base()
          |> Slice.waiting(assigned: true)
          |> Slice.waiting()

        answer = Slice.call(context, CreateEpic, %{name: "Additional queued work"})
        [_, epic_id] = Regex.run(~r/ID: ([^,\s]+)/, answer)

        Slice.call(context, AssignStoryToEpic, %{
          story_number: context.waiting.number,
          epic_name: "Additional queued work"
        })

        {:ok, Map.put(context, :queued_epic_id, epic_id)}
      end

      when_ "the agent adds the waiting epic to that copy's queue", context do
        answer =
          Slice.call(context, AssignEpicToWorkingCopy, %{
            epic_id: context.queued_epic_id,
            working_copy_id: context.scope.active_working_copy_id
          })

        {:ok, Map.put(context, :queue_answer, answer)}
      end

      then_ "the placement is confirmed and both teammates still read their current story", context do
        assert context.queue_answer =~ context.scope.cwd

        for agent <- context.team do
          answer = Slice.next(context, %{agent_id: agent.id})
          assert answer =~ "# Story #{context.story.number}:"
          refute answer =~ "# Story #{context.waiting.number}:"
        end

        {:ok, context}
      end
    end
  end
end
