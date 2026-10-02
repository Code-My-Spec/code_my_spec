defmodule CodeMySpecSpex.Story682.Criterion1616Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1616 — A component cannot be made to depend on itself.

  Surface: `add_dependency`. The architecture view drops self-loops when it
  draws, so it cannot tell a refused edge from a stored one; the tool's own
  refusal is the observable.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A component cannot be made to depend on itself", criterion: 1616 do
    scenario "the agent names the same component on both ends" do
      given_ "a context", context do
        app = context.project.module_name || "MyApp"

        accounts =
          ComponentHelpers.create(context.scope,
            name: "Accounts",
            module_name: "#{app}.Accounts",
            type: "context"
          )

        {:ok, Map.put(context, :accounts, accounts)}
      end

      when_ "the agent adds a dependency of it on itself", context do
        {:reply, reply, _frame} =
          AddDependency.execute(
            %{source_component_id: context.accounts.id, target_component_id: context.accounts.id},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is refused, and says why", context do
        assert context.reply.isError
        assert response_text(context.reply) =~ "cannot depend on itself"
        {:ok, context}
      end
    end
  end
end
