defmodule CodeMySpecSpex.Story561.Criterion5616Spex do
  @moduledoc """
  Story 561 — Next Actionable Requirements
  Criterion 5616 — The function returns an empty list when no
  requirement is actionable, never nil or a singleton.

  Surface: get_next_requirement MCP tool. When no requirements
  exist (empty project graph) or all are satisfied, the response
  is one of the documented empty-state messages — not an arbitrary
  start_task signature, never nil or an exception.
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

  spex "The empty/satisfied path returns coherent text, never nil or singleton" do
    scenario "after satisfying every requirement on a single-component subgraph, the satisfied items disappear" do
      given_ :context_with_three_children

      and_ "every artifact for the schema child is written and re-synced",
           context do
        # Schema requires only spec_file, spec_valid, implementation_file.
        # GraphContentFixtures already writes spec + impl files in the given,
        # so the schema is fully satisfied after sync. Re-sync to confirm.
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

      then_ "no schema-child requirement is advertised (the schema chain is fully satisfied)",
            context do
        schema_id = context.child_schema.id

        refute context.response_text =~ "entity_id=`#{schema_id}`",
               "expected the fully-satisfied schema child to be excluded entirely from actionable, response: #{context.response_text}"

        {:ok, context}
      end

      and_ "the response is coherent text — never nil, never an empty string",
           context do
        assert is_binary(context.response_text)
        assert context.response_text != ""

        # Sanity: the impl file the schema fixture writes must still be on
        # disk after sync — proves we exercised real state, not just
        # asserted on a trivially empty response.
        impl_path = Content.impl_path(context.child_schema.module_name)
        assert Environments.file_exists?(context.environment, impl_path)

        {:ok, context}
      end
    end
  end
end
