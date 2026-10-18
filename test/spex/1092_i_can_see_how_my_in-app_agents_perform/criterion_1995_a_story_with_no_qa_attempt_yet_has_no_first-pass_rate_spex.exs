defmodule CodeMySpecSpex.Story1092.Criterion1995Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 1995 -- A story with no QA attempt yet has no first-pass rate.

  Rule: QA first-pass rate and rework rounds are shown per story and per
  team.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story never submitted to QA has no first-pass rate yet", criterion: 1995 do
    scenario "a story has never been submitted to QA" do
      given_ "a released story that has never gone to QA", context do
        reply = join_working_copy(context, "/tmp/spex-1995", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_story(scope,
            title: "Never QA'd",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        frame = %Frame{assigns: %{current_scope: scope}}

        _resp =
          ToolLibrary.run(
            "set_active_story",
            %{story_number: story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:story, story)}
      end

      when_ "I look at how my agents perform", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "its first-pass rate is shown as not yet measured", context do
        assert context.html =~ "not yet measured" or context.html =~ "no QA attempt",
               "a story with no QA attempt does not say its first-pass rate is unmeasured"

        {:ok, context}
      end

      then_ "and it is not counted as a failed first pass", context do
        refute context.html =~ "0%" and context.html =~ context.story.title,
               "a story with no QA attempt is shown with a 0% first-pass rate, which reads as a failure rather than unmeasured"

        {:ok, context}
      end
    end
  end
end
