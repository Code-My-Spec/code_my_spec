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

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

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
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "review_file and review_valid are not advertised",
            context do
        refute context.response_text =~ "requirement_name=`review_file`",
               "expected review_file to be blocked while parent spec is missing"

        refute context.response_text =~ "requirement_name=`review_valid`",
               "expected review_valid to be blocked while parent spec is missing"

        {:ok, context}
      end

      and_ "the parent's spec_file is the actionable head", context do
        parent_id = context.parent_context.id

        signature =
          ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/

        assert Regex.match?(signature, context.response_text),
               "expected parent spec_file to be the actionable head, response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
