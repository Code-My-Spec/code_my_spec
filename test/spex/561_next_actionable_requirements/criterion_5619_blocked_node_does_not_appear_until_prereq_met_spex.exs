defmodule CodeMySpecSpex.Story561.Criterion5619Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5619 — A node whose own check would pass but with one
  unsatisfied prereq does not appear in actionable.

  Surface: get_next_requirement. We exercise this by deleting the
  parent context's spec file (so spec_valid is unsatisfied), then
  asserting that downstream child-scoped requirements (which depend
  on parent.spec_valid through the template) are not advertised —
  the chain is correctly gated.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias CodeMySpec.Environments
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocked nodes are excluded until prereqs are satisfied" do
    scenario "child review work is not advertised while parent spec is missing" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "the parent context's spec file is removed", context do
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

      then_ "no review_file or review_valid is actionable",
            context do
        blocked_names = ["review_file", "review_valid"]

        actionable_reviews =
          Enum.filter(context.actionable, fn req -> req.name in blocked_names end)

        assert actionable_reviews == [],
               "expected review_file/review_valid to be blocked while parent spec is missing, got actionable: #{inspect(Enum.map(actionable_reviews, &{&1.entity_type, &1.entity_id, &1.name}))}"

        {:ok, context}
      end

      and_ "the parent's spec_file is in the actionable set", context do
        parent_id = context.parent_context.id

        match =
          Enum.find(context.actionable, fn req ->
            req.name == "spec_file" and
              req.entity_type == "component" and
              req.entity_id == parent_id
          end)

        assert match,
               "expected parent spec_file in actionable, got #{inspect(Enum.map(context.actionable, &{&1.entity_type, &1.entity_id, &1.name}))}"

        {:ok, context}
      end
    end
  end
end
