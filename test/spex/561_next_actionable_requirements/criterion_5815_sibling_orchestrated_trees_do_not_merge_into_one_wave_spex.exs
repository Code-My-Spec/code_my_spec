defmodule CodeMySpecSpex.Story561.Criterion5815Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5815 — When two orchestrated trees (different
  parent_entity_id) have actionable nodes with identical sort keys,
  the wave contains nodes from only one tree. The other tree's nodes
  do not appear in the same response.

  Surface: get_next_requirement MCP tool. Two top-level contexts
  with linked priority-1 stories are synced. The response surfaces
  one tree only; the other is queued.
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

  spex "Sibling orchestrated trees do not merge into one wave" do
    scenario "only one of two sibling contexts surfaces in the response" do
      given_ "two top-level contexts synced and linked to priority-1 stories", context do
        env = context.environment

        for module <- ["AlphaContext", "BetaContext"] do
          :ok =
            Environments.write_file(
              env,
              Content.spec_path(module),
              Content.context_spec(module, type: "context", dependencies: [])
            )

          :ok =
            Environments.write_file(env, Content.impl_path(module), Content.impl_file(module))
        end

        {:ok, sync_live, _html} = live(context.conn, "/app/projects/#{context.project.name}/files")
        sync_live |> element("button[phx-click='sync']") |> render_click()

        alpha = Fixtures.get_component_by_module_name(context.scope, "AlphaContext")
        beta = Fixtures.get_component_by_module_name(context.scope, "BetaContext")

        StoryHelpers.create_and_link(context.scope, "AlphaContext",
          title: "Alpha story",
          description: "As a user, I want Alpha shipped first.",
          acceptance_criteria: ["Alpha works"],
          priority: 1
        )

        StoryHelpers.create_and_link(context.scope, "BetaContext",
          title: "Beta story",
          description: "As a user, I want Beta shipped after.",
          acceptance_criteria: ["Beta works"],
          priority: 1
        )

        {:ok, Map.merge(context, %{alpha: alpha, beta: beta})}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response includes exactly one of the two trees, not both", context do
        text = context.response_text
        alpha_present = text =~ "entity_id=`#{context.alpha.id}`"
        beta_present = text =~ "entity_id=`#{context.beta.id}`"

        assert alpha_present or beta_present,
               "neither tree surfaced — fixture didn't actualize either chain. Response: #{text}"

        refute alpha_present and beta_present,
               "expected only one orchestrated tree in the wave, got both. Response: #{text}"

        {:ok, context}
      end
    end
  end
end
