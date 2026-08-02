defmodule CodeMySpecSpex.Story562.Criterion6496Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 6496 — A reopened story requirement returns to the head
  over its surface component's downstream work.

  Codifies the cross-scope edge gating rule (3ca9979d) at the
  story↔component layer: when a story was fully satisfied and its
  surface component's downstream work is in flight, reopening a
  story-scope requirement (here: deleting the story's BDD spec file to
  break `bdd_specs_passing` / `bdd_specs_exist`) must immediately
  surface that story requirement at the head — and exclude in-flight
  component requirements from the response — until the story
  requirement is satisfied again.

  Surface: get_next_requirement MCP tool. The base topology comes from
  `:fully_satisfied_project`, which links a story to a `Reservations`
  context. An additional sibling component is introduced with only a
  spec on disk to make a component requirement actionable in parallel,
  then the story's BDD spec file is removed to reopen its story-scope
  requirement.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.StoryHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reopened story requirement returns to head over component work in flight" do
    scenario "deleting the story's BDD spec surfaces the story requirement ahead of an in-flight component" do
      given_ :fully_satisfied_project

      and_ "an in-flight component exists with a spec on disk and no implementation",
           context do
        module_name = "Reservations.InFlight"

        :ok =
          Environments.write_file(
            context.environment,
            Content.spec_path(module_name),
            Content.child_spec(module_name, type: "schema", dependencies: [])
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      and_ "the story's BDD spec file is removed, breaking the story's BDD requirements",
           context do
        story = StoryHelpers.fetch(context.scope, context.story.id)
        [criterion | _] = story.criteria

        :ok =
          Environments.delete_file(
            context.environment,
            Fixtures.spec_file_path(story, criterion)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response advertises a story-scope requirement at the head",
            context do
        assert context.response_text =~ ~s(entity_type=`story`),
               "expected a story-scope requirement at the head; got: #{context.response_text}"

        {:ok, context}
      end

      then_ "the response does not advertise any component-scope requirements",
            context do
        refute context.response_text =~ ~s(entity_type=`component`),
               "expected no component-scope requirements while a story requirement is unsatisfied; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
