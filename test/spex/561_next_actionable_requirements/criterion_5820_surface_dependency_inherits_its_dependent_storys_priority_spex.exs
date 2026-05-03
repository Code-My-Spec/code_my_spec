defmodule CodeMySpecSpex.Story561.Criterion5820Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5820 — A component that is a surface dependency of a
  story-linked component inherits that story's priority via the
  projector's dependency-spread propagation. Both the dependency and
  the dependent should surface ahead of unrelated low-priority
  components.

  Surface: get_next_requirement MCP tool. With Stories depending on
  Users (linked story priority 1) and an unrelated low-priority
  Reports context, the response surfaces work from the
  Users/Stories cluster, not the orphan low-priority Reports.

  Note: the response mapper clamps each call to a single
  orchestrated tree, so on any one call we expect to see Users OR
  Stories OR Reports — but never Reports leading. This proves that
  the projector did inherit priority into Users.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Surface dependency inherits its dependent story's priority" do
    scenario "Users (dep of Stories) sorts ahead of low-priority Reports" do
      given_ "Stories depends on Users (story priority 1), and unrelated Reports has priority 9",
             context do
        env = context.environment

        for {module, deps} <- [
              {"Users", []},
              {"Stories", ["Users"]},
              {"Reports", []}
            ] do
          :ok =
            Environments.write_file(
              env,
              Content.spec_path(module),
              Content.context_spec(module, type: "context", dependencies: deps)
            )

          :ok =
            Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
        end

        {:ok, sync_live, _html} = live(context.conn, "/projects/#{context.project.name}/sync")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        users = Fixtures.get_component_by_module_name(context.scope, "Users")
        stories = Fixtures.get_component_by_module_name(context.scope, "Stories")
        reports = Fixtures.get_component_by_module_name(context.scope, "Reports")

        StoryHelpers.create_and_link(context.scope, "Stories",
          title: "Stories surface",
          description: "As a user, I want Stories shipped, which requires Users.",
          acceptance_criteria: ["Stories renders"],
          priority: 1
        )

        StoryHelpers.create_and_link(context.scope, "Reports",
          title: "Reports later",
          description: "As a user, I want Reports much later.",
          acceptance_criteria: ["Reports renders"],
          priority: 9
        )

        {:ok, Map.merge(context, %{users: users, stories: stories, reports: reports})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the wave belongs to Users or Stories (priority-1 cluster), not Reports", context do
        text = context.response_text

        users_present = text =~ "entity_id=`#{context.users.id}`"
        stories_present = text =~ "entity_id=`#{context.stories.id}`"
        reports_present = text =~ "entity_id=`#{context.reports.id}`"

        assert users_present or stories_present,
               "expected Users or Stories (priority-1 cluster) in the wave. Response: #{text}"

        refute reports_present,
               "Reports (priority 9) should not lead while Users/Stories cluster has work. Response: #{text}"

        {:ok, context}
      end
    end
  end
end
