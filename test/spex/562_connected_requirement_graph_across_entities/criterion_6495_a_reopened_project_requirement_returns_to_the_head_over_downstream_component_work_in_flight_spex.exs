defmodule CodeMySpecSpex.Story562.Criterion6495Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 6495 — A reopened project requirement returns to the head
  over downstream component work in flight.

  Codifies the cross-scope edge gating rule (3ca9979d): when the project
  chain was satisfied and component work is in flight, reopening a
  project-chain requirement (here: deleting the project's persona to
  break `personas_complete`) must immediately surface that project
  requirement at the head — and exclude in-flight component requirements
  from the response — until the project requirement is satisfied again.

  Surface: get_next_requirement MCP tool. The base topology comes from
  `:fully_satisfied_project` (everything green; `next_actionable` returns
  `[]`), then an additional sibling component is introduced with only a
  spec on disk to make a component requirement actionable in parallel.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Personas.Tools.DeletePersona
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Reopened project requirement returns to head over component work in flight" do
    scenario "deleting the persona surfaces personas_complete ahead of an in-flight component" do
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
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      and_ "the project's persona is deleted, breaking personas_complete",
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          DeletePersona.execute(%{id: context.persona_id}, frame)

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "the response advertises personas_complete at the head",
            context do
        assert context.response_text =~ "personas_complete",
               "expected personas_complete in the response; got: #{context.response_text}"

        assert context.response_text =~ ~s(entity_type=`project`),
               "expected a project-scope requirement at the head; got: #{context.response_text}"

        {:ok, context}
      end

      then_ "the response does not advertise any component-scope requirements",
            context do
        refute context.response_text =~ ~s(entity_type=`component`),
               "expected no component-scope requirements while a project requirement is unsatisfied; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
