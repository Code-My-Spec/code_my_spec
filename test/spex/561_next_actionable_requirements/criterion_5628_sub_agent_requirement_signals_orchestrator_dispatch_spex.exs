defmodule CodeMySpecSpex.Story561.Criterion5628Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5628 — A sub_agent requirement carries an
  `orchestrated_by` reference, signaling that the caller should
  dispatch through the orchestrator rather than execute the
  sub_agent task in isolation.

  Surface: get_next_requirement. When the actionable head is an
  orchestrated requirement (a child component requirement governed
  by a context orchestrator), the response renders the
  orchestration prompt block — a header that names the parent
  context and its orchestrator — instead of a flat list. Plain
  start_task lines still appear underneath so the caller has
  unambiguous dispatch metadata.
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

  spex "sub_agent items signal dispatch through their orchestrator" do
    scenario "the response carries a parent-scoped orchestration header for sub_agent work" do
      given_ :context_with_three_children_in_satisfied_project

      and_ "all child spec files are removed and the project re-synced",
           context do
        Enum.each(
          [
            context.child_schema.module_name,
            context.child_repository.module_name,
            context.child_service.module_name
          ],
          fn module_name ->
            :ok =
              Environments.delete_file(context.environment, Content.spec_path(module_name))
          end
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

      then_ "the response carries a parent-scoped header naming the orchestrating context",
            context do
        parent_name = context.parent_context.module_name

        assert context.response_text =~ "## #{parent_name}",
               "expected the parent context name `#{parent_name}` in the orchestration header, response: #{context.response_text}"

        {:ok, context}
      end

      and_ "the response advertises actionable child component work under that header",
           context do
        actionable_lines =
          context.response_text
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ "start_task"))

        assert actionable_lines != [],
               "expected sub_agent child requirements to advertise actionable lines, response: #{context.response_text}"

        # At least one line must reference a child component — verifies that
        # the sub_agent dispatch info is present in the response.
        component_lines =
          Enum.filter(actionable_lines, fn line ->
            line =~ "component `" or line =~ "entity_type=`component`"
          end)

        assert component_lines != [],
               "expected component-level actionable lines under the orchestration header"

        {:ok, context}
      end
    end
  end
end
