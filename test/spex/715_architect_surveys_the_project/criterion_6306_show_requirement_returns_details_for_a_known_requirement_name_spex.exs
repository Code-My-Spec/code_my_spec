defmodule CodeMySpecSpex.Story715.Criterion6306Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6306 — show_requirement returns details for a known requirement name.

  When the project's requirement graph contains a node with a known
  name and the agent calls `show_requirement` with that name, the
  response text reports the requirement's name, description, status,
  entity, execution type, and validation type.

  Surface: `ShowRequirement` MCP tool, backed by
  `Requirements.RequirementGraph.compute_all/1`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ShowRequirement

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Requirement-query tools resolve their reference and return requirement details or done/total summaries; an unknown reference returns a not-found error rather than crashing" do
    scenario "show_requirement returns details for a known requirement name" do
      given_ :synced_context_component

      when_ ~s|the agent calls show_requirement with name "spec_file"|, context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ShowRequirement.execute(%{name: "spec_file"}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response reports the requirement name", context do
        assert context.body =~ ~r/^#\s+spec_file/m,
               "expected `# spec_file` header in response, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response includes the requirement's description", context do
        # The `spec_file` requirement's description in the registry is
        # "Context specification file exists" — assert the body carries
        # it between the header and the **Status:** field.
        assert context.body =~ "Context specification file exists",
               "expected requirement description in response, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response reports the status, entity, execution, and validation fields", context do
        for key <- ~w(Status Entity Execution Validation) do
          assert context.body =~ "**#{key}:**",
                 "expected `**#{key}:**` field in response, got:\n#{context.body}"
        end

        {:ok, context}
      end
    end
  end
end
