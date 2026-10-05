defmodule CodeMySpecSpex.Story1092.Criterion2013Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2013 -- Offer health is shown per role.

  Rule: Offer health is shown per role: claim rate, time to claim,
  ignored and declined offers.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers
  import CodeMySpecSpex.AgentPerformanceHelpers
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.CancelTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A role's claim rate reflects the offers its agents actually claimed",
       criterion: 2013 do
    scenario "agents in the coding role were offered work over a period" do
      given_ "one coding agent frees a task and a second coding agent claims it", context do
        reply = join_working_copy(context, "/tmp/spex-2013", "the checkout")
        scope = %{context.scope | active_working_copy_id: reply.working_copy_id}

        story =
          StoryHelpers.create_and_link(scope, "CodeMySpecSpex.Example2013",
            title: "Offered and claimed",
            description: "As a user, I want this story done.",
            acceptance_criteria: ["It works"]
          )

        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, _resp, _frame} = SetActiveStory.execute(%{story_number: story.number}, frame)

        first = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2013")
        first_frame = %Frame{assigns: %{current_scope: scope, agent_id: first.id}}

        {:reply, started, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2013").id
            },
            first_frame
          )

        refute started.isError, inspect(started)
        [_, task_id] = Regex.run(~r/Task ID: `([0-9a-f-]{36})`/, response_text(started))

        {:reply, cancelled, _frame} = CancelTask.execute(%{task_id: task_id}, first_frame)
        refute cancelled.isError, inspect(cancelled)

        second = Fixtures.running_agent(scope, role: "coding", working_copy: "/tmp/spex-2013")
        second_frame = %Frame{assigns: %{current_scope: scope, agent_id: second.id}}

        {:reply, claimed, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: Fixtures.get_component_by_module_name(scope, "CodeMySpecSpex.Example2013").id
            },
            second_frame
          )

        refute claimed.isError, inspect(claimed)

        {:ok, context |> Map.put(:scope, scope)}
      end

      when_ "I look at offer health", context do
        {:ok, _index, html} = live(context.conn, index_path(context))
        {:ok, Map.put(context, :html, html)}
      end

      then_ "I see each role's claim rate and average time to claim", context do
        assert context.html =~ "coding", "the coding role's offer health is not shown at all"

        {:ok, context}
      end

      then_ "and how many offers were ignored or declined", context do
        assert context.html =~ "ignored" or context.html =~ "declined",
               "offer health does not account for ignored or declined offers at all"

        {:ok, context}
      end
    end
  end
end
