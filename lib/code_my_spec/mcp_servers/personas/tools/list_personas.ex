defmodule CodeMySpec.McpServers.Personas.Tools.ListPersonas do
  @moduledoc """
  Lists every persona on the active project.

  Use this during the intake conversation to check whether a persona has
  already been researched, or to surface related personas the PM might want
  to reference or reuse.
  """

  use Anubis.Server.Component, type: :tool

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case personas(frame) do
      {:ok, personas} -> {:reply, PersonasMapper.personas_list_response(personas), frame}
      {:error, reason} -> {:reply, PersonasMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, personas} <- personas(frame) do
      {:ok, Enum.map(personas, &row/1)}
    end
  end

  defp personas(frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      {:ok, Personas.list_personas(scope)}
    end
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
