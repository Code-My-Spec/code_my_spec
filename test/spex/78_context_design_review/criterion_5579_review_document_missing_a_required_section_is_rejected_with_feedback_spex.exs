defmodule CodeMySpecSpex.Story78.Criterion5579Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5579 — Review document missing a required section is rejected
  with feedback.

  Surface: `list_requirements` MCP tool. After a review document at the
  canonical path is missing a required `design_review` section,
  `review_file` shows satisfied (the file exists) but `review_valid`
  remains unsatisfied — the graph holds the agent at the review gate
  until the document conforms.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  @review_path ".code_my_spec/spec/example_context/design_review.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Review document missing a required section is rejected with feedback" do
      given_ :synced_context_component

      given_ "a review document is written at the canonical path missing the Conclusion section",
             context do
        :ok = Environments.write_file(context.environment, @review_path, invalid_review())

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

      then_ "review_file is satisfied because the file exists", context do
        assert context.response_text =~ "Component: ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[x\]\s+\*\*review_file\*\*/,
               "expected review_file to satisfy on file_exists alone — the file landed at the canonical path"

        {:ok, context}
      end

      and_ "review_valid stays unsatisfied because the document fails schema validation", context do
        assert context.response_text =~ ~r/\[ \]\s+\*\*review_valid\*\*/,
               "expected review_valid to remain unsatisfied — missing the Conclusion section blocks schema validation"

        {:ok, context}
      end
    end
  end

  defp invalid_review do
    """
    # Design Review

    ## Overview

    Reviewed ExampleContext together with its child components.

    ## Architecture

    - Separation of concerns is sound

    ## Integration

    - Public APIs delegated cleanly
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
