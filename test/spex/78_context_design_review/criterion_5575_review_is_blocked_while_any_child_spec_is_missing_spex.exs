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
      given_ :synced_context_in_satisfied_project

      given_ "a child Component is on disk only as an impl (no spec)", context do
        :ok = Environments.write_file(context.environment, @child_impl_path, child_impl_content())

        {:ok, sync_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        # The impl file written above shifted the analysis fingerprints —
        # re-stamp so tests_passing stays fresh and the missing child
        # spec_file is what surfaces.
        CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

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

        # Intent: the actionable must be scoped to a component (the child whose
        # spec is missing), not to the parent context or to a story. We assert
        # the entity_type rather than the entity_name because the orchestrate
        # prompt rubric (see .code_my_spec/knowledge/skills/description_rubric.md
        # and agent_task_guide.md) deliberately keeps orchestrate strings as
        # static routing signals, so the human-readable module name is no
        # longer pinned in the rendered output — the entity_type + entity_id
        # in the dispatch signature is the stable identifier.
        assert context.response_text =~ "entity_type=`component`",
               "expected the actionable to be scoped to a component (the child whose spec is missing)"

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
