defmodule CodeMySpecSpex.Story561.Criterion5626Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5626 — A project where everything unsatisfied is
  blocked by an unsatisfied prereq also returns no false-positive
  on the blocked work.

  Surface: get_next_requirement. We construct a real "blocked"
  state by syncing a context topology, then deleting the parent's
  spec file so its downstream requirements (review, impl, tests)
  all have unsatisfied prereqs. The response must NOT advertise any
  of those blocked nodes — only the upstream parent.spec_file (the
  one un-blocked actionable) is allowed to surface.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.GraphAssertions
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  @actionable_color "#f5f5f7"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocked-by-prereq nodes do not render in actionable color" do
    scenario "with parent spec missing, downstream parent requirements render as blocked, not actionable" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed and re-synced", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      when_ "the engineer opens the requirements graph", context do
        {:ok, _live, html} =
          live(context.conn, "/app/projects/#{context.project.name}/requirements/graph?preload=true")

        {:ok, Map.put(context, :graph, GraphAssertions.extract_graph!(html))}
      end

      then_ "no downstream parent requirement renders in actionable color",
            context do
        parent_id = context.parent_context.id

        downstream =
          ~w(review_file review_valid implementation_file test_file test_spec_alignment tests_passing)

        actionable_downstream =
          Enum.filter(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] in downstream and
              n["attributes"]["color"] == @actionable_color
          end)

        assert actionable_downstream == [],
               "expected blocked parent downstream reqs to NOT render as actionable, found: #{inspect(Enum.map(actionable_downstream, & &1["attributes"]["name"]))}"

        {:ok, context}
      end

      and_ "the upstream parent.spec_file renders in actionable color",
           context do
        parent_id = context.parent_context.id

        node =
          Enum.find(context.graph["nodes"], fn n ->
            n["attributes"]["entity_id"] == parent_id and
              n["attributes"]["name"] == "spec_file"
          end)

        assert node && node["attributes"]["color"] == @actionable_color,
               "expected parent spec_file to render as actionable (#{@actionable_color}), got #{inspect(node && node["attributes"]["color"])}"

        {:ok, context}
      end
    end
  end
end
