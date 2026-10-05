defmodule CodeMySpecSpex.Story1092.Criterion1993Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1993 -- A story still in flight has no finished cycle time.

  Rule: Each team's stories show cycle time from release to promotion,
  broken down by stage.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story not yet promoted has a running cycle time, not a zero one", criterion: 1993 do
    scenario "a story was released and assigned to a team but has not been promoted" do
      given_ "a ready story released and assigned to this copy's team an hour ago", context do
        reply = join_working_copy(context, "/tmp/spex-1993", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "Still in flight",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

        :ok = Fixtures.age_story(scope, story.id, 3600)

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:story, story)}
      end

      when_ "I look at how my agents perform", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "its cycle time is shown as still running", context do
        assert context.html =~ "running" or context.html =~ "in progress",
               "a story released but not yet promoted does not show its cycle time as still running"

        {:ok, context}
      end

      then_ "and it is not reported as a completed cycle of zero", context do
        refute context.html =~ "0h" and context.html =~ context.story.title,
               "a story still in flight is shown with a zero-length completed cycle"

        {:ok, context}
      end
    end
  end
end
