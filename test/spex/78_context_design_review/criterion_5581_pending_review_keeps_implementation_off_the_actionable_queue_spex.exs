defmodule CodeMySpecSpex.Story78.Criterion5581Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5581 — Pending review keeps implementation off the actionable
  queue.

  Surface: `get_next_requirement` MCP tool. With the spec phase fully
  satisfied but no review document yet, the next actionable requirement
  is `review_file` — never the child's implementation_file. The graph
  refuses to surface implementation work until the review gate releases.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ComponentHelpers

  @child_spec_path ".code_my_spec/spec/example_context/item.spec.md"
  @child_impl_path "lib/example_context/item.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Pending review keeps implementation off the actionable queue" do
      given_ :synced_context_in_satisfied_project

      given_ "a child Component exists with a valid spec on disk", context do
        child =
          ComponentHelpers.create(context.scope,
            type: "schema",
            module_name: "ExampleContext.Item",
            name: "ExampleContext Item",
            parent_component_id: context.component.id
          )

        :ok = Environments.write_file(context.environment, @child_spec_path, child_spec_content())
        :ok = Environments.write_file(context.environment, @child_impl_path, child_impl_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, Map.put(context, :child, child)}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "the next actionable is the review, not implementation", context do
        assert context.response_text =~ "review_file",
               "expected the review_file to be the next actionable while the review document is missing"

        refute context.response_text =~ "implementation_file",
               "expected implementation_file to stay buried until the review gate releases"

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

  defp child_impl_content do
    """
    defmodule ExampleContext.Item do
      @moduledoc false
    end
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
