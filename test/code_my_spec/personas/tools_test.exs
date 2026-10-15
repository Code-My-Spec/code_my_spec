defmodule CodeMySpec.Personas.ToolsTest do
  @moduledoc """
  The persona tools as a domain owns them: called through
  `CodeMySpec.Tools.run/3`, the path every surface takes, and reached from code
  mode by name like any other scriptable tool.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.CodeMode
  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.Tools.{GetPersona, ListPersonas}
  alias CodeMySpec.Repo
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.Tools

  setup do
    scope = full_scope_fixture()
    %{scope: scope, context: %{scope: scope}, project_id: scope.active_project_id}
  end

  describe "get_persona" do
    test "fetches by slug", %{context: context, project_id: project_id} do
      persona = insert_persona(project_id, "founder", "Founder", "Solo founder")

      assert {:ok, text} = Tools.run(GetPersona, %{"slug" => "founder"}, context)
      assert text =~ "Persona: \"Founder\""
      assert text =~ persona.id
    end

    test "fetches by persona_id when slug not given", %{context: context, project_id: project_id} do
      persona = insert_persona(project_id, "agency_pm", "Agency PM", nil)

      assert {:ok, text} = Tools.run(GetPersona, %{"persona_id" => persona.id}, context)
      assert text =~ "Agency PM"
    end

    test "slug wins when both are given", %{context: context, project_id: project_id} do
      founder = insert_persona(project_id, "founder", "Founder", nil)
      insert_persona(project_id, "agency_pm", "Agency PM", nil)

      assert {:ok, text} =
               Tools.run(
                 GetPersona,
                 %{"slug" => "founder", "persona_id" => Ecto.UUID.generate()},
                 context
               )

      assert text =~ founder.id
    end

    test "neither slug nor persona_id is refused", %{context: context} do
      assert {:error, text} = Tools.run(GetPersona, %{}, context)
      assert text =~ ~r/provide either.*slug.*or.*persona_id/i
    end

    test "a slug the project lacks is not found", %{context: context} do
      assert {:error, text} = Tools.run(GetPersona, %{"slug" => "nobody"}, context)
      assert text =~ ~r/not found/i
    end
  end

  describe "list_personas" do
    test "an empty project says so", %{context: context} do
      assert {:ok, text} = Tools.run(ListPersonas, %{}, context)
      assert text =~ "No personas on this project yet"
    end

    test "lists the project's personas", %{context: context, project_id: project_id} do
      insert_persona(project_id, "founder", "Founder", nil)
      insert_persona(project_id, "agency_pm", "Agency PM", nil)

      assert {:ok, text} = Tools.run(ListPersonas, %{}, context)
      assert text =~ "Personas on this project (2)"
      assert text =~ "`founder`"
      assert text =~ "`agency_pm`"
    end
  end

  describe "the library" do
    test "describes each tool with the JSON Schema of its arguments" do
      assert {:ok, tool} = ToolLibrary.fetch("link_persona_to_story")
      [registration] = Enum.filter(ToolLibrary.registrations(), &(&1.tool == tool))

      assert registration.input_schema["required"] |> Enum.sort() ==
               ["persona_id", "story_number"]

      assert registration.input_schema["properties"]["story_number"]["type"] == "integer"
    end

    test "code mode reaches a domain tool by name, and gets its data", %{scope: scope} do
      insert_persona(scope.active_project_id, "founder", "Founder", nil)

      assert {:ok, [%{"slug" => "founder"}]} =
               CodeMode.catalog(scope)["list_personas"].invoke.(%{})
    end

    test "code mode refuses arguments the tool does not declare", %{scope: scope} do
      assert {:invalid_call, message} =
               CodeMode.catalog(scope)["get_persona"].invoke.(%{"nickname" => "x"})

      assert message =~ "unknown argument"
    end
  end

  defp insert_persona(project_id, slug, name, headline) do
    {:ok, persona} =
      %Persona{}
      |> Persona.changeset(%{slug: slug, name: name, headline: headline, project_id: project_id})
      |> Repo.insert()

    persona
  end
end
