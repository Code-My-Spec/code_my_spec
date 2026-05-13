defmodule CodeMySpec.McpServers.Personas.Tools.GetPersonaTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.GetPersona
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

  describe "GetPersona tool" do
    test "fetches by slug", %{frame: frame, project_id: project_id} do
      persona = insert_persona(project_id, "founder", "Founder", "Solo founder")

      {:reply, response, ^frame} = GetPersona.execute(%{slug: "founder"}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Founder"
      assert text =~ "founder"
      assert text =~ persona.id
    end

    test "fetches by id when slug not given", %{frame: frame, project_id: project_id} do
      persona = insert_persona(project_id, "agency_pm", "Agency PM", nil)

      {:reply, response, ^frame} = GetPersona.execute(%{id: persona.id}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Agency PM"
      assert text =~ "agency_pm"
    end

    test "slug wins when both slug and id are given",
         %{frame: frame, project_id: project_id} do
      founder = insert_persona(project_id, "founder", "Founder", nil)
      _agency_pm = insert_persona(project_id, "agency_pm", "Agency PM", nil)

      {:reply, response, ^frame} =
        GetPersona.execute(%{slug: "founder", id: Ecto.UUID.generate()}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Founder"
      assert text =~ founder.id
    end

    test "returns error when neither slug nor id is provided", %{frame: frame} do
      {:reply, response, ^frame} = GetPersona.execute(%{}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/provide either.*slug.*or.*id/i
    end

    test "returns not_found when slug doesn't exist on the project", %{frame: frame} do
      {:reply, response, ^frame} = GetPersona.execute(%{slug: "nobody"}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/not found/i
    end

    test "returns not_found when id doesn't exist on the project", %{frame: frame} do
      {:reply, response, ^frame} =
        GetPersona.execute(%{id: Ecto.UUID.generate()}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/not found/i
    end
  end

  defp insert_persona(project_id, slug, name, headline) do
    {:ok, persona} =
      %Persona{}
      |> Persona.changeset(%{
        slug: slug,
        name: name,
        headline: headline,
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

  defp error_text(response) do
    (response_text(response) || "") <> "\n" <> inspect(response)
  end
end
