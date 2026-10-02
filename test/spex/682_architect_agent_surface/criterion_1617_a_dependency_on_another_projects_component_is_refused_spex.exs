defmodule CodeMySpecSpex.Story682.Criterion1617Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 1617 — A dependency on a component in another project is refused.

  `Components.create_dependency/2` links any two rows, so the scoping is the
  tool's. Surface: `add_dependency`, observed through `show_architecture`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A dependency on a component in another project is refused", criterion: 1617 do
    scenario "the agent names a component it cannot see" do
      given_ "a context here, and one in another project", context do
        app = context.project.module_name || "MyApp"

        web =
          ComponentHelpers.create(context.scope,
            name: "Web",
            module_name: "#{app}.Web",
            type: "context"
          )

        elsewhere = Fixtures.other_project_scope(context.scope, "Elsewhere")

        theirs =
          ComponentHelpers.create(elsewhere,
            name: "Billing",
            module_name: "Elsewhere.Billing",
            type: "context"
          )

        {:ok, Map.merge(context, %{web: web, theirs: theirs})}
      end

      when_ "the agent adds a dependency on the other project's component", context do
        {:reply, reply, _frame} =
          AddDependency.execute(
            %{source_component_id: context.web.id, target_component_id: context.theirs.id},
            %Frame{assigns: %{current_scope: context.scope}}
          )

        {:ok, Map.put(context, :reply, reply)}
      end

      then_ "it is refused, and nothing is drawn", context do
        assert context.reply.isError
        assert response_text(context.reply) =~ "No component #{context.theirs.id} in this project"

        {:reply, architecture, _frame} =
          ShowArchitecture.execute(%{}, %Frame{assigns: %{current_scope: context.scope}})

        refute response_text(architecture) =~ "-->"
        {:ok, context}
      end
    end
  end
end
