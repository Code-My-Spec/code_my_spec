defmodule CodeMySpecSpex.Story682.Criterion1615Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1615 — An agent adds a dependency between two components and
  removes it again, with no spec file involved.

  Components as records, step 1 (3aeb66cf). An edge used to arrive only by a
  spec file's `## Dependencies` being synced. Surface: `add_dependency` and
  `remove_dependency`, observed through `show_architecture`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpec.McpServers.Components.Tools.RemoveDependency
  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  defp architecture(context) do
    {:reply, reply, _frame} = ShowArchitecture.execute(%{}, frame(context))
    response_text(reply)
  end

  defp edge(context), do: "#{context.app}_web --> #{context.app}_accounts"

  spex "An agent adds a dependency between two components and removes it again, with no spec file involved",
    criterion: 1615 do
    scenario "the edge is written and taken away through the tools" do
      given_ "two contexts that do not depend on each other", context do
        app = context.project.module_name || "MyApp"
        context = Map.put(context, :app, String.downcase(app))

        web =
          ComponentHelpers.create(context.scope,
            name: "Web",
            module_name: "#{app}.Web",
            type: "context"
          )

        accounts =
          ComponentHelpers.create(context.scope,
            name: "Accounts",
            module_name: "#{app}.Accounts",
            type: "context"
          )

        refute architecture(context) =~ edge(context)
        {:ok, Map.merge(context, %{web: web, accounts: accounts})}
      end

      when_ "the agent adds a dependency of the first on the second", context do
        {:reply, reply, _frame} =
          AddDependency.execute(
            %{source_component_id: context.web.id, target_component_id: context.accounts.id},
            frame(context)
          )

        {:ok, Map.put(context, :added, reply)}
      end

      then_ "the architecture shows the edge", context do
        refute context.added.isError, response_text(context.added)
        assert architecture(context) =~ edge(context)
        {:ok, context}
      end

      when_ "the agent removes it", context do
        {:reply, reply, _frame} =
          RemoveDependency.execute(
            %{source_component_id: context.web.id, target_component_id: context.accounts.id},
            frame(context)
          )

        {:ok, Map.put(context, :removed, reply)}
      end

      then_ "the edge is gone", context do
        refute context.removed.isError, response_text(context.removed)
        refute architecture(context) =~ edge(context)
        {:ok, context}
      end
    end
  end
end
