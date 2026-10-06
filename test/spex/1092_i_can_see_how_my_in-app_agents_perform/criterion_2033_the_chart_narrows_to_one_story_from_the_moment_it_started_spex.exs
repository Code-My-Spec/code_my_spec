defmodule CodeMySpecSpex.Story1092.Criterion2033Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2033 -- The chart narrows to one story from the moment it
  started.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Narrowing the chart to a story shows only its own activity, from the moment it started",
       criterion: 2033 do
    scenario "an earlier story's activity, then a second story that starts and records its own turn" do
      given_ "an earlier story's own turn, then a second story that starts and records its own turn",
             context do
        {:ok, main_copy} =
          WorkingCopies.issue(context.scope, nil,
            label: "the main checkout",
            device: Fixtures.device_fixture(context.scope)
          )

        {:ok, _} = WorkingCopies.designate_main(context.scope, main_copy.id)

        reply = join_working_copy(context, "/tmp/spex-2033", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}
        Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2033")

        earlier =
          StoryHelpers.create_story(scope,
            title: "Earlier story",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        earlier_frame = %Frame{assigns: %{current_scope: scope}}

        {:reply, resp, _frame} =
          SetActiveStory.execute(%{story_number: earlier.number}, earlier_frame)

        refute resp.isError, inspect(resp)

        :ok =
          Fixtures.record_turn(
            scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 20, "output_tokens" => 30}
            },
            session_id: "spex-2033-earlier",
            agent_role: "coding"
          )

        target =
          StoryHelpers.create_story(scope,
            title: "Narrowed story",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        target_frame = %Frame{assigns: %{current_scope: scope}}

        {:reply, resp2, _frame} =
          SetActiveStory.execute(%{story_number: target.number}, target_frame)

        refute resp2.isError, inspect(resp2)

        :ok =
          Fixtures.record_turn(
            scope,
            %{"model" => "claude-sonnet-5-5", "messages" => []},
            %{
              "model" => "claude-sonnet-5-5",
              "content" => [%{"type" => "text", "text" => "done"}],
              "usage" => %{"input_tokens" => 40, "output_tokens" => 50}
            },
            session_id: "spex-2033-target",
            agent_role: "coding"
          )

        {:ok, context |> Map.put(:scope, scope) |> Map.put(:target, target)}
      end

      when_ "I narrow the chart to the story that started second", context do
        {:ok, index, _html} = live(context.conn, index_path(context))

        html =
          index
          |> element("form[data-test='performance-filter']")
          |> render_change(%{"working_copy_id" => "", "story_id" => to_string(context.target.id)})

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart shows only that story's own activity, from the moment it started", context do
        assert context.html =~ "90 tokens",
               "the narrowed story's own token total (90) is not shown once the chart is narrowed to it"

        refute context.html =~ "140 tokens",
               "activity from before the story started is still included once the chart is narrowed to it"

        {:ok, context}
      end
    end
  end
end
