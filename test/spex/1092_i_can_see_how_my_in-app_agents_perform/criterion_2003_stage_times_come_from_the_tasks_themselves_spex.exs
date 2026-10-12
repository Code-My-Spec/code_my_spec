defmodule CodeMySpecSpex.Story1092.Criterion2003Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2003 -- Stage times come from the tasks themselves.

  Rule: Each team's stories show cycle time from release to promotion,
  broken down by stage, and a stage waiting on a person shows that wait
  separately from the stage's own active time.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A build stage's time comes from its own tasks opening and closing, not from the release clock",
    criterion: 2003 do
    scenario "a story's tasks each opened and closed during its build, one of them waiting on a person" do
      given_ "a released story whose build task waited on a tap-out for half an hour", context do
        reply = join_working_copy(context, "/tmp/spex-2003", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        frame = %Frame{assigns: %{current_scope: scope}}

        {:reply, created, _frame} =
          CreateComponent.execute(
            %{name: "Example2003", type: "context", module_name: "CodeMySpecSpex.Example2003"},
            frame
          )

        refute created.isError, inspect(created)
        component = Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2003")

        story =
          StoryHelpers.create_and_link(scope, "CodeMySpecSpex.Example2003",
            title: "Build-stage timing",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

        :ok = Fixtures.age_story(scope, story.id, 7200)

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2003")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        {:reply, started, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: component.id
            },
            asking
          )

        refute started.isError, inspect(started)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

        {:reply, tapped, _frame} =
          TapOut.execute(
            %{task_id: task_id, reason: "need a product decision before writing this"},
            asking
          )

        refute tapped.isError, inspect(tapped)
        [_, permission_id] = Regex.run(~r/request_id=`([0-9a-f-]{36})`/, response_text(tapped))
        :ok = Fixtures.age_permission(scope, permission_id, 1_800)

        {:ok,
         context
         |> Map.put(:scope, scope)
         |> Map.put(:story, story)
         |> Map.put(:agent, agent)}
      end

      when_ "its cycle time is shown", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, context |> Map.put(:index, index) |> Map.put(:html, html)}
      end

      then_ "each stage's time is taken from when its tasks opened and closed", context do
        assert context.html =~ "build",
               "the story's performance has no build stage at all"

        build_stage =
          context.index |> element("[data-test='stage'][data-stage='build']") |> render()

        refute build_stage =~ "2h",
               "the build stage's time matches the hours since release rather than the task's own, much shorter, open-to-close span"

        {:ok, context}
      end

      then_ "and a stage waiting on a person shows that wait separately", context do
        assert context.html =~ "waiting" or context.html =~ "blocked",
               "the half hour the build task spent waiting on a tap-out decision is not shown apart from the stage's own active time"

        {:ok, context}
      end
    end
  end
end
