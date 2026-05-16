defmodule CodeMySpecSpex.Story715.Criterion6313Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6313 — show_architecture renders a Mermaid flowchart of contexts and their dependencies.

  When two context components exist where one declares a dependency on
  the other, `show_architecture` returns text that:
    1. Begins with `flowchart TD`.
    2. Carries a node line for each context (using sanitized lowercase
       module names as ids).
    3. Carries an edge line `source --> target` connecting the
       dependent and depended-on contexts.

  Surface: `ShowArchitecture` MCP tool, backed by
  `Architecture.MermaidProjector`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "show_architecture renders a Mermaid flowchart with surface components as nodes and dependencies as edges" do
    scenario "show_architecture renders a Mermaid flowchart of contexts and their dependencies" do
      given_ :cross_context_dependency

      when_ "the agent calls show_architecture", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ShowArchitecture.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response begins with `flowchart TD`", context do
        assert String.starts_with?(context.body, "flowchart TD"),
               "expected mermaid header `flowchart TD`, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "each context appears as a sanitized node line with its module name", context do
        assert context.body =~ ~r/^users\[Users\]/m,
               "expected node line `users[Users]` in mermaid output, got:\n#{context.body}"

        assert context.body =~ ~r/^stories\[Stories\]/m,
               "expected node line `stories[Stories]` in mermaid output, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the dependency appears as an edge between the sanitized node ids", context do
        assert context.body =~ ~r/^stories --> users$/m,
               "expected edge line `stories --> users` in mermaid output, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
