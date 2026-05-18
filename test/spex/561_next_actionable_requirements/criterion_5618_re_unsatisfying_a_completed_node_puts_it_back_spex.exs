defmodule CodeMySpecSpex.Story561.Criterion5618Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5618 — Re-unsatisfying a previously-completed node puts
  it back in the actionable list.

  Surface: get_next_requirement. After syncing a context (parent
  spec_file satisfied), the engineer deletes the parent's spec file
  and re-syncs. The response now advertises spec_file for that
  parent component as actionable again — proving the actionable
  computation is fresh against current state, not cached.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Deleting a completed artifact re-surfaces its requirement" do
    scenario "the parent spec_file reappears as actionable after deletion" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the engineer deletes the parent context's spec file from disk",
           context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the engineer computes the actionable set", context do
        actionable = RequirementGraph.next_actionable(context.scope)
        {:ok, Map.put(context, :actionable, actionable)}
      end

      then_ "the parent context's spec_file is in the actionable list",
            context do
        parent_id = context.parent_context.id

        match =
          Enum.find(context.actionable, fn req ->
            req.name == "spec_file" and
              req.entity_type == "component" and
              req.entity_id == parent_id
          end)

        assert match,
               "expected the parent's spec_file in the actionable list, got #{inspect(Enum.map(context.actionable, &{&1.entity_type, &1.entity_id, &1.name}))}"

        {:ok, context}
      end
    end
  end
end
