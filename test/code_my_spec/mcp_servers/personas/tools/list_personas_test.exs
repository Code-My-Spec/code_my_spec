defmodule CodeMySpec.McpServers.Personas.Tools.ListPersonasTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.ListPersonas
  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Repo
  alias Ecto.Adapters.SQL.Sandbox

  import CodeMySpec.UsersFixtures

  setup do
    :ok = Sandbox.checkout(Repo)

    scope = full_scope_fixture()

    frame = %Frame{assigns: %{current_scope: scope, working_dir: scope.cwd}}

    {:ok, scope: scope, frame: frame, project_id: scope.active_project_id}
  end

  describe "ListPersonas tool" do
    test "returns empty-state text when the project has no personas", %{frame: frame} do
      {:reply, response, ^frame} = ListPersonas.execute(%{}, frame)

      assert response.type == :tool
      assert response.isError == false

      text = response_text(response)
      assert text =~ "No personas on this project yet"
    end

    test "lists personas when present", %{frame: frame, project_id: project_id} do
      insert_persona(project_id, "founder", "Founder")
      insert_persona(project_id, "agency_pm", "Agency PM")

      {:reply, response, ^frame} = ListPersonas.execute(%{}, frame)

      text = response_text(response)
      assert text =~ "Personas on this project (2)"
      assert text =~ "Founder"
      assert text =~ "`founder`"
      assert text =~ "Agency PM"
      assert text =~ "`agency_pm`"
    end
  end

  defp insert_persona(project_id, slug, name) do
    {:ok, persona} =
      %Persona{}
      |> Persona.changeset(%{
        slug: slug,
        name: name,
        project_id: project_id
      })
      |> Repo.insert()

    persona
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end
end
