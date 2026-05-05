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

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.GraphContentFixtures, as: Content
  alias CodeMySpecSpex.TaskResponseHelpers

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

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "downstream parent requirements (review, impl, tests) are not advertised",
            context do
        parent_id = context.parent_context.id

        downstream =
          ~w(review_file review_valid implementation_file test_file test_spec_alignment tests_passing)

        Enum.each(downstream, fn name ->
          refute context.response_text =~
                   ~r/requirement_name=`#{name}`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/,
                 "expected blocked parent #{name} to stay out of actionable while parent spec is missing, response: #{context.response_text}"
        end)

        {:ok, context}
      end

      and_ "the upstream parent.spec_file IS advertised — the only un-blocked node",
           context do
        parent_id = context.parent_context.id

        assert context.response_text =~
                 ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{parent_id}`/,
               "expected parent spec_file to surface as the upstream actionable, response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
