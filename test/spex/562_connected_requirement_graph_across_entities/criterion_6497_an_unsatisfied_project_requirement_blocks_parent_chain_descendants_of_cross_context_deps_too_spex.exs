defmodule CodeMySpecSpex.Story562.Criterion6497Spex do
  @moduledoc """
  Story 562 — Connected Requirement Graph Across Entities
  Criterion 6497 — An unsatisfied project requirement blocks
  parent-chain descendants of cross-context deps too.

  Extends the cross-scope edge gating rule (3ca9979d) to cover
  components that inherit priority via the `parent_component_id`
  cascade but live outside any container's child-scope template.
  Without this, a non-container intermediate (e.g. an
  `Environments.Cli` module under an `Environments` context) leaves
  its descendants priority-tethered but edge-orphaned — actionable
  even when the project chain is unsatisfied.

  Surface: get_next_requirement MCP tool. The base topology comes
  from `:fully_satisfied_project`; an additional cross-context dep
  (`External`) is written with a non-container module (`External.Util`)
  and a grandchild (`External.Util.Helper`), Reservations is rewritten
  to declare `External` as a dependency, then `personas_complete` is
  broken by deleting the persona.
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

  spex "Project requirement blocks parent-chain descendants of cross-context deps" do
    scenario "an external context's grandchild via a non-container intermediate is gated by an unsatisfied project requirement" do
      given_ :fully_satisfied_project

      and_ "an external context exists with a non-container intermediate and a grandchild, and Reservations declares it as a dependency",
           context do
        env = context.environment

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("External"),
            Content.context_spec("External", type: "context", dependencies: [])
          )

        :ok =
          Environments.write_file(env, Content.impl_path("External"), Content.impl_file("External"))

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("External.Util"),
            Content.child_spec("External.Util", type: "module", dependencies: [])
          )

        :ok =
          Environments.write_file(
            env,
            Content.spec_path("External.Util.Helper"),
            Content.child_spec("External.Util.Helper", type: "module", dependencies: [])
          )

        # Rewrite Reservations to declare External as a cross-context
        # dependency so the kickoff fan-out reaches into External's
        # subtree.
        :ok =
          Environments.write_file(
            env,
            Content.spec_path("Reservations"),
            Content.context_spec("Reservations", type: "context", dependencies: ["External"])
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        # The External files just written shifted the analysis fingerprints,
        # so :fully_satisfied_project's fresh-run stamp is stale — re-stamp
        # so tests_passing stays satisfied and personas_complete (broken
        # next) is the one unsatisfied requirement.
        CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

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

        {:ok, context}
      end

      then_ "the response does not advertise the parent-chain descendant",
            context do
        refute context.response_text =~ "External.Util.Helper",
               "expected External.Util.Helper (parent-chain descendant of a cross-context dep) to be blocked; got: #{context.response_text}"

        {:ok, context}
      end

      then_ "the response does not advertise the non-container intermediate or the dep itself",
            context do
        refute context.response_text =~ "External.Util",
               "expected External.Util (non-container intermediate) to be blocked; got: #{context.response_text}"

        refute context.response_text =~ ~s(entity_type=`component`),
               "expected no component-scope requirements while a project requirement is unsatisfied; got: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
