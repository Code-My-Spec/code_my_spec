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
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpecSpex.GraphContentFixtures, as: Content

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Blocked-by-prereq nodes do not surface in actionable" do
    scenario "with parent spec missing, downstream parent requirements stay out of actionable" do
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

      when_ "the engineer computes the actionable set", context do
        actionable = RequirementGraph.next_actionable(context.scope)
        {:ok, Map.put(context, :actionable, actionable)}
      end

      then_ "downstream parent requirements (review, impl, tests) are not in actionable",
            context do
        parent_id = context.parent_context.id

        downstream =
          ~w(review_file review_valid implementation_file test_file test_spec_alignment tests_passing)

        blocked_actionable =
          Enum.filter(context.actionable, fn req ->
            req.entity_type == "component" and req.entity_id == parent_id and
              req.name in downstream
          end)

        assert blocked_actionable == [],
               "expected blocked parent downstream reqs to stay out of actionable, found: #{inspect(Enum.map(blocked_actionable, & &1.name))}"

        {:ok, context}
      end

      and_ "the upstream parent.spec_file IS in actionable",
           context do
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
