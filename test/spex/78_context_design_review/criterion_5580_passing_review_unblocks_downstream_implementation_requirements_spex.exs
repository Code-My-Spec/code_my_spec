defmodule CodeMySpecSpex.Story78.Criterion5580Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5580 — Passing review unblocks downstream implementation
  requirements.

  Surface: `list_requirements` MCP tool. With both the spec phase and
  review phase satisfied, the child's `implementation_file` requirement
  is no longer blocked — list_requirements shows it as actionable
  (unsatisfied but with all prerequisites met), confirming the review
  gate has released downstream implementation work.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.ComponentHelpers

  @child_spec_path ".code_my_spec/spec/example_context/item.spec.md"
  @review_path ".code_my_spec/spec/example_context/design_review.md"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Passing review unblocks downstream implementation requirements" do
      given_ :synced_context_component

      given_ "a child Component exists with a valid spec on disk (no impl yet)", context do
        child =
          ComponentHelpers.create(context.scope,
            type: "schema",
            module_name: "ExampleContext.Item",
            name: "ExampleContext Item",
            parent_component_id: context.component.id
          )

        :ok = Environments.write_file(context.environment, @child_spec_path, child_spec_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, Map.put(context, :child, child)}
      end

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

      then_ "review_valid is satisfied for the context", context do
        assert context.response_text =~ "Component: ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[x\]\s+\*\*review_valid\*\*/,
               "expected review_valid to be satisfied — the review gate has passed"

        {:ok, context}
      end

      and_ "the child's implementation_file requirement is unblocked and unsatisfied", context do
        assert context.response_text =~ "Component: ExampleContext.Item",
               "expected the child to be present in the requirements list"

        assert context.response_text =~ ~r/\[ \]\s+\*\*implementation_file\*\*/,
               "expected the child's implementation_file to be unsatisfied (no impl file written) but no longer gated by the review"

        {:ok, context}
      end
    end
  end

  defp child_spec_content do
    """
    # ExampleContext.Item

    ## Type

    schema

    A schema for example context items.

    ## Fields

    - `name` — string

    ## Dependencies

    - None
    """
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
