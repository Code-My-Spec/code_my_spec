defmodule CodeMySpecSpex.Story78.Criterion5575Spex do
  @moduledoc """
  Story 78 — Context Design Review
  Criterion 5575 — Review is blocked while any child spec is missing.

  Surface: `get_next_requirement` MCP tool. With the context spec valid
  but a child component's spec missing on disk, the next actionable
  requirement is the missing child's `spec_file` — never `review_file`.
  The review never surfaces past an unsatisfied prerequisite in the
  spec phase.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  @child_impl_path "lib/example_context/item.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Context Design Review" do
    scenario "Review is blocked while any child spec is missing" do
      given_ :synced_context_component

      given_ "a child Component is on disk only as an impl (no spec)", context do
        :ok = Environments.write_file(context.environment, @child_impl_path, child_impl_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/sync")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, context}
      end

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "the next actionable references the missing child spec_file", context do
        assert context.response_text =~ "spec_file",
               "expected the missing child spec_file to surface in the actionable list"

        assert context.response_text =~ "ExampleContext.Item",
               "expected the actionable to be scoped to the child whose spec is missing"

        {:ok, context}
      end

      and_ "review_file is not the surfaced actionable", context do
        refute context.response_text =~ "review_file",
               "expected review_file to stay buried while a child spec is unsatisfied"

        {:ok, context}
      end
    end
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
