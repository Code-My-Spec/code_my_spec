defmodule CodeMySpecSpex.Story1026.Criterion2048Spex do
  @moduledoc """
  Story 1026 — A copy needs no team to accept queue additions or removals.
  Each scenario joins a fresh copy without staffing it and drives the queue
  controls on its page. The no-agents message anchors the teamless premise.
  """
  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.WorkingCopyHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Queue edits work on a copy with no team", criterion: 2048 do
    scenario "An unstaffed copy accepts a story into its queue" do
      given_ "a copy without agents and an unassigned story", context do
        {:ok, teamless_copy(context)}
      end

      when_ "I add the story to the unstaffed copy's queue", context do
        add_story(context)
        {:ok, context}
      end

      then_ "the story is queued while the copy still has no agents", context do
        assert has_element?(context.copy_view, "[data-test='no-agents']")
        assert has_element?(context.copy_view, queued_story(context))
        {:ok, context}
      end
    end

    scenario "An unstaffed copy allows a queued story to be removed" do
      given_ "a copy without agents and a story added through its queue control", context do
        context = teamless_copy(context)
        add_story(context)
        {:ok, context}
      end

      when_ "I remove the story from the unstaffed copy's queue", context do
        context.copy_view
        |> element(
          "[data-test='remove-story-from-queue'][data-story-number='#{context.queued_story.number}']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "the story is no longer queued and the copy still has no agents", context do
        assert has_element?(context.copy_view, "[data-test='no-agents']")
        refute has_element?(context.copy_view, queued_story(context))
        {:ok, context}
      end
    end
  end

  defp teamless_copy(context) do
    reply =
      WorkingCopyHelpers.join_working_copy(
        context,
        "/workspace/teamless-queue",
        "Queue without a team"
      )

    story =
      StoryHelpers.create_story(context.scope,
        title: "Work for an unstaffed copy #{System.unique_integer([:positive])}",
        description: "Queued independently of a team's current story",
        acceptance_criteria: ["It works"]
      )

    {:ok, view, _html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{reply[:working_copy_id]}"
      )

    Map.merge(context, %{copy_view: view, queued_story: story})
  end

  defp add_story(context) do
    context.copy_view
    |> form("[data-test='add-story-to-queue']",
      queue: %{story_number: context.queued_story.number}
    )
    |> render_submit()
  end

  defp queued_story(context),
    do: "[data-test='queued-story'][data-story-number='#{context.queued_story.number}']"
end
