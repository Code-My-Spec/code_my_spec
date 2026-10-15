defmodule CodeMySpec.Personas.Tools.ListPersonas do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Tools

  @impl true
  def name, do: "list_personas"

  @impl true
  def description do
    """
    Lists every persona on the active project.

    Use this during the intake conversation to check whether a persona has
    already been researched, or to surface related personas the PM might want
    to reference or reuse.
    """
  end

  @impl true
  def params, do: %{}

  @impl true
  def call(_params, context) do
    case personas(context) do
      {:ok, personas} -> {:ok, Tools.list_text(personas)}
      {:error, reason} -> Tools.error(reason)
    end
  end

  @impl true
  def script_result(_params, context) do
    case personas(context) do
      {:ok, personas} -> {:ok, Enum.map(personas, &row/1)}
      {:error, reason} -> Tools.error(reason)
    end
  end

  defp personas(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         do: {:ok, Personas.list_personas(scope)}
  end

  defp row(persona) do
    %{
      "id" => persona.id,
      "slug" => persona.slug,
      "name" => persona.name,
      "headline" => persona.headline,
      "persona_type" => to_string(persona.persona_type)
    }
  end
end
