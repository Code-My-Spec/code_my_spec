defmodule CodeMySpecSpex.Story78.Criterion5578Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5578 — Schema-conforming review document evaluates as valid.

  Surface: `list_requirements` MCP tool. After a review document landing
  at the canonical path satisfies every section of the `design_review`
  schema, both `review_file` and `review_valid` show satisfied — the
  graph has advanced past the review gate.
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
    scenario "Schema-conforming review document evaluates as valid" do
      given_ :synced_context_component

      given_ "a schema-conforming review document is written at the canonical path", context do
        :ok = Environments.write_file(context.environment, @review_path, valid_review())

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

      then_ "review_file is satisfied for the context", context do
        assert context.response_text =~ "Component: ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[x\]\s+\*\*review_file\*\*/,
               "expected review_file to be satisfied once the canonical document exists"

        {:ok, context}
      end

      and_ "review_valid is satisfied", context do
        assert context.response_text =~ ~r/\[x\]\s+\*\*review_valid\*\*/,
               "expected review_valid to satisfy because the document conforms to the design_review schema"

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
