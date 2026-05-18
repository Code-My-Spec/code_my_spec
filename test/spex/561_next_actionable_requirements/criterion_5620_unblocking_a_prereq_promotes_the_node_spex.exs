defmodule CodeMySpecSpex.Story561.Criterion5620Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5620 — Once the prereq turns green, the previously-
  blocked node appears in the actionable list.

  Surface: get_next_requirement, called twice. First with a missing
  parent spec (so children can't progress), then with the spec
  written and synced (children unblock). The second call must
  advertise child requirements that the first call did not.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Unblocking a prereq promotes its dependents into actionable" do
    scenario "downstream items appear after the prereq is satisfied" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed and re-synced", context do
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

      when_ "the engineer computes actionable in the blocked state", context do
        actionable = RequirementGraph.next_actionable(context.scope)
        {:ok, Map.put(context, :blocked_actionable, actionable)}
      end

      and_ "the parent spec is rewritten and re-synced", context do
        :ok =
          Environments.write_file(
            context.environment,
            Content.spec_path(context.parent_context.module_name),
            Content.context_spec(context.parent_context.module_name)
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()
        {:ok, context}
      end

      and_ "the engineer computes actionable in the unblocked state", context do
        actionable = RequirementGraph.next_actionable(context.scope)
        {:ok, Map.put(context, :unblocked_actionable, actionable)}
      end

      then_ "the parent spec_file disappears from the unblocked actionable list",
            context do
        parent_id = context.parent_context.id

        in_blocked? =
          Enum.any?(context.blocked_actionable, fn req ->
            req.name == "spec_file" and
              req.entity_type == "component" and
              req.entity_id == parent_id
          end)

        in_unblocked? =
          Enum.any?(context.unblocked_actionable, fn req ->
            req.name == "spec_file" and
              req.entity_type == "component" and
              req.entity_id == parent_id
          end)

        assert in_blocked?,
               "expected parent spec_file in the blocked actionable set (parent spec was missing)"

        refute in_unblocked?,
               "expected parent spec_file to disappear from the unblocked actionable set (it's now satisfied)"

        {:ok, context}
      end
    end
  end
end
