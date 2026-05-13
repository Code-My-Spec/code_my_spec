defmodule CodeMySpecSpex.Story560.Criterion5154Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5154 — Personas do not leak across project boundaries. A persona
  created on a project in account A does not appear when listing from a
  project in account B. Same-account leakage is covered by 5153; this
  covers the cross-account flavor of the same project-scope invariant.

  Surface: `create_persona` + `list_personas` MCP tools, called against
  two different scopes (different active_project_id, different account).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.ListPersonas
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Personas do not leak across project boundaries (cross-account variant)" do
    scenario "A persona created in the first account's project does not appear in a second account's project list" do
      given_ "the agent creates a persona in the user's first account's project",
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
               "expected create_persona to succeed in the first project, got: #{inspect(response)}"

        {:ok, context}
      end

      and_ "a second account is created with its own project, and a scope is built for that project",
           context do
        second_account = Fixtures.account_with_owner_fixture(context.user, %{name: "Globex"})

        second_scope =
          Fixtures.user_scope_fixture(context.user, second_account)

        second_project =
          Fixtures.project_fixture(second_scope, %{name: "Product Z", module_name: "ProductZ"})

        second_full_scope = %{
          second_scope
          | active_project: second_project,
            active_project_id: second_project.id
        }

        {:ok, Map.put(context, :second_scope, second_full_scope)}
      end

      when_ "the agent calls list_personas with the second project's scope", context do
        frame = %Frame{assigns: %{current_scope: context.second_scope}}
        {:reply, response, _frame} = ListPersonas.execute(%{}, frame)
        {:ok, Map.put(context, :list_response, response)}
      end

      then_ "the list_personas response renders but does not include the first project's persona",
            context do
        refute context.list_response.isError == true,
               "expected list_personas to succeed in the second project, got: #{inspect(context.list_response)}"

        body = TaskResponseHelpers.response_text(context.list_response)

        # Anchor: the response must be a real list rendering — not an empty
        # error string that would pass any refute. The list_response helper
        # always renders a header or summary line even when zero personas exist.
        assert body =~ ~r/persona|Persona/,
               "anchor: expected the list_personas response to render its listing format. Response: #{inspect(body)}"

        refute body =~ "Founder",
               "expected the persona 'Founder' from the first project to NOT appear in the second project's library. Response: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
