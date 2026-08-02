defmodule CodeMySpecSpex.Story78.Criterion5577Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5577 — Review written off-path leaves the canonical path
  unsatisfied.

  Surface: `list_requirements` MCP tool. After a review document is
  written to a non-canonical path, the graph still reports
  `review_file` as unsatisfied — the file_exists check resolves only the
  canonical path, never any wandering review file the agent placed
  elsewhere.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  @off_path_review ".code_my_spec/spec/example_context_review.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Review written off-path leaves the canonical path unsatisfied" do
      given_ :synced_context_component

      given_ "the agent writes a review document at a non-canonical path", context do
        :ok = Environments.write_file(context.environment, @off_path_review, valid_review())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, context}
      end

      when_ "the agent calls list_requirements", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "review_file for the context remains unsatisfied", context do
        assert context.response_text =~ "Component: ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[ \]\s+\*\*review_file\*\*/,
               "expected review_file to stay unsatisfied — the off-path file does not satisfy the canonical check"

        {:ok, context}
      end
    end
  end

  defp valid_review do
    """
    # Design Review

    ## Overview

    Reviewed ExampleContext together with its child components.

    ## Architecture

    - Separation of concerns is sound
    - Component types align with their stated roles

    ## Integration

    - Public APIs are clearly delegated from the parent context

    ## Conclusion

    Design is sound and ready for implementation.
    """
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
