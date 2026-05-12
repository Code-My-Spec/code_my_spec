defmodule CodeMySpecSpex.Story560.Criterion5153Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5153 — A persona created while working on one project is
  visible from another project in the same account. Personas are
  account-scoped, not project-scoped.

  Surface: `create_persona` + `list_personas` MCP tools. The scope's
  active_project is swapped between two projects in the same account;
  list_personas returns the persona in both.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.ListPersonas
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Persona is account-scoped, not project-scoped" do
    scenario "Persona created in Project X appears in Project Y's library (same account)" do
      given_ "the agent creates a persona while the active project is the setup_active_project default",
             context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CreatePersona.execute(
            %{
              slug: "founder",
              name: "Founder",
              headline: "Solo founder shipping a product"
            },
            frame
          )

        refute response.isError == true,
               "expected create_persona to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      and_ "a second project is added in the same account and made the active project",
           context do
        second_project =
          Fixtures.project_fixture(context.scope, %{name: "Product Y", module_name: "ProductY"})

        Fixtures.select_active_project(context.scope, second_project.id)

        second_scope = %{
          context.scope
          | active_project: second_project,
            active_project_id: second_project.id
        }

        {:ok, Map.put(context, :second_scope, second_scope)}
      end

      when_ "the agent calls list_personas with the second project's scope", context do
        frame = %Frame{assigns: %{current_scope: context.second_scope}}
        {:reply, response, _frame} = ListPersonas.execute(%{}, frame)
        {:ok, Map.put(context, :list_response, response)}
      end

      then_ "the persona appears in the second project's library", context do
        refute context.list_response.isError == true,
               "expected list_personas to succeed, got: #{inspect(context.list_response)}"

        body = TaskResponseHelpers.response_text(context.list_response)

        assert body =~ "Founder",
               "expected the persona 'Founder' to appear in the list_personas response from the second project (same account). Response: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
