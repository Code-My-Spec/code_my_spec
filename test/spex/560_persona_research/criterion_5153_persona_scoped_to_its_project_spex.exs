defmodule CodeMySpecSpex.Story560.Criterion5153Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5153 — A persona created on one project is NOT visible from a
  sibling project in the same account. Personas are project-scoped — the
  "shared library" framing was dropped in favor of per-project ownership
  that matches the per-project disk layout.

  Surface: `create_persona` + `list_personas` MCP tools. The scope's
  active_project is swapped to a sibling project in the same account;
  list_personas does NOT return the persona on the second project.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.ListPersonas
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Persona is project-scoped, not account-scoped" do
    scenario "Persona created on Project X does not appear in Project Y's library (same account)" do
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

      then_ "the persona does NOT appear in the second project's library", context do
        refute context.list_response.isError == true,
               "expected list_personas to succeed, got: #{inspect(context.list_response)}"

        body = TaskResponseHelpers.response_text(context.list_response)

        assert body =~ ~r/persona|Persona/i,
               "anchor: expected list_personas to render its listing format. Response: #{inspect(body)}"

        refute body =~ "Founder",
               "expected the persona 'Founder' to NOT appear in the second project's library, since personas are project-scoped. Response: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
