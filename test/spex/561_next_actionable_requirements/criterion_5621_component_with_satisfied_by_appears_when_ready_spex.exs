defmodule CodeMySpecSpex.Story561.Criterion5621Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5621 — A regular component's spec_file with
  satisfied_by present appears in actionable when its prereqs are
  met (or it has none).

  Surface: get_next_requirement. With three children synced under
  a parent context, after deleting one child's spec file, the
  child's spec_file becomes actionable — proving that satisfied_by
  values inherited from the template surface real start_task calls.
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

  spex "Component requirement with satisfied_by appears when actionable" do
    scenario "the schema child's spec_file becomes actionable after its file is removed" do
      given_ :context_with_three_children

      and_ "the schema child's spec file is removed and re-synced", context do
        :ok =
          Environments.delete_file(
            context.environment,
            Content.spec_path(context.child_schema.module_name)
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

      then_ "the schema child's spec_file is advertised as actionable",
            context do
        child_id = context.child_schema.id

        signature =
          ~r/requirement_name=`spec_file`,\s*entity_type=`component`,\s*entity_id=`#{child_id}`/

        assert Regex.match?(signature, context.response_text),
               "expected the schema child's spec_file to be in actionable, response: #{context.response_text}"

        {:ok, context}
      end
    end
  end
end
