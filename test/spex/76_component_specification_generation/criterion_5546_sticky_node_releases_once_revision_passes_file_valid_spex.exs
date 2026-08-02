defmodule CodeMySpecSpex.Story76.Criterion5546Spex do
  @moduledoc """
  Story 76 — Component Specification Generation
  Criterion 5546 — Sticky node releases once revision passes file_valid.

  Surface: `list_requirements` MCP tool. After a Component starts with
  an invalid spec on disk, the spec_valid node holds the agent. Once
  the spec is rewritten to pass file_valid and re-synced, list_requirements
  shows spec_valid satisfied — the graph has advanced past the sticky node.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  @spec_path ".code_my_spec/spec/example_context.spec.md"
  @impl_path "lib/example_context.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Specification Generation" do
    scenario "Sticky node releases once revision passes file_valid" do
      given_ "ExampleContext is synced with an INVALID spec on disk", context do
        env = context.environment

        :ok = Environments.write_file(env, @spec_path, "# ExampleContext\n\n(missing required sections)\n")
        :ok = Environments.write_file(env, @impl_path, "defmodule ExampleContext do\nend\n")

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, context}
      end

      when_ "the agent revises the spec and re-syncs", context do
        :ok = Environments.write_file(context.environment, @spec_path, valid_context_spec())

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, response_text(response))}
      end

      then_ "spec_valid for ExampleContext is now satisfied", context do
        assert context.response_text =~ "ExampleContext",
               "expected the response to scope to the synced ExampleContext component"

        assert context.response_text =~ ~r/\[x\]\s+\*\*spec_valid\*\*/,
               "expected spec_valid to release once the revision passes file_valid"

        {:ok, context}
      end
    end
  end

  defp valid_context_spec do
    """
    # ExampleContext

    ## Type

    context

    An example context for BDD specs.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ```elixir
    @spec noop() :: :ok
    ```

    ## Dependencies

    - None

    ## Components

    ### ExampleContext.Noop

    Placeholder child module.
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
