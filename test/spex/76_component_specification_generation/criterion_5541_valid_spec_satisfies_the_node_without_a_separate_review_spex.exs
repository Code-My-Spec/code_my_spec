defmodule CodeMySpecSpex.Story76.Criterion5541Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5541 — Valid spec satisfies the node without a separate review.

  Surface: `list_requirements` MCP tool. After a context Component is
  synced with a valid spec on disk, both `spec_file` and `spec_valid`
  satisfy in the same pass — no separate quality reviewer is invoked
  before the graph advances past spec validation.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Valid spec satisfies the node without a separate review" do
      given_ :synced_context_component

      when_ "the agent calls list_requirements", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "spec_file is satisfied for ExampleContext", context do
        assert context.response_text =~ "ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[x\]\s+\*\*spec_file\*\*/,
               "expected spec_file to show as satisfied"

        {:ok, context}
      end

      and_ "spec_valid is satisfied without a separate review running", context do
        assert context.response_text =~ ~r/\[x\]\s+\*\*spec_valid\*\*/,
               "expected spec_valid to satisfy on file_valid alone — no separate quality review gate"

        {:ok, context}
      end
    end
  end
end
