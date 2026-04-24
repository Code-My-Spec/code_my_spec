defmodule CodeMySpec.McpServers.Personas.Tools.ListPersonas do
  @moduledoc """
  Lists every persona in the active account.

  Use this during the intake conversation to check whether a persona has
  already been researched, or to surface related personas the PM might want
  to reference or reuse.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.McpServers.Personas.PersonasMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Personas

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame) do
      personas = Personas.list_personas(scope)
      {:reply, PersonasMapper.personas_list_response(personas), frame}
    else
      {:error, reason} ->
        {:reply, PersonasMapper.error(reason), frame}
    end
  end
end
