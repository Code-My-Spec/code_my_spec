defmodule CodeMySpecSpex.Story1092.Criterion2003Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2003 -- Stage times come from the tasks themselves.

  Rule: Each team's stories show cycle time from release to promotion,
  broken down by stage, and a stage waiting on a person shows that wait
  separately from the stage's own active time.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
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
        {reply, socket} = join_working_copy_socket(context, "/tmp/spex-2003", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        frame = %Frame{assigns: %{current_scope: scope}}

        created =
          ToolLibrary.run(
            "create_component",
            %{name: "Example2003", type: "context", module_name: "CodeMySpecSpex.Example2003"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, created), inspect(created)
        component = Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2003")

        story =
          StoryHelpers.create_and_link(scope, "CodeMySpecSpex.Example2003",
            title: "Build-stage timing",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        _resp =
          ToolLibrary.run(
            "set_active_story",
            %{story_number: story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        :ok = Fixtures.age_story(scope, story.id, 7200)

        agent = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2003")
        asking = %Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

        started =
          as_an_empty_checkout(socket, fn ->
            ToolLibrary.run(
              "start_task",
              %{
                requirement_name: "implementation_file",
                entity_type: "component",
                entity_id: component.id
              },
              Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
            )
          end)

        assert match?({:ok, _}, started), inspect(started)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

        tapped =
          ToolLibrary.run(
            "tap_out",
            %{task_id: task_id, reason: "need a product decision before writing this"},
            Map.put(asking.assigns, :scope, asking.assigns[:current_scope])
          )

        assert match?({:ok, _}, tapped), inspect(tapped)
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
        chart = chart_data(context.index, "[data-test='story-stages-chart']")
        row = story_row(chart, context.story.title)

        assert Map.has_key?(row.hours, "build"),
               "the story's performance has no build stage at all"

        refute row.hours["build"] >= 2,
               "the build stage's time matches the hours since release rather than the task's own, much shorter, open-to-close span"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and a stage waiting on a person shows that wait separately", context do
        assert Enum.any?(context.row.details, &(&1 =~ "Waited on")),
               "the half hour the build task spent waiting on a tap-out decision is not shown apart from the stage's own active time"

        {:ok, context}
      end
    end
  end
end
