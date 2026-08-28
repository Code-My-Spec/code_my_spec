defmodule CodeMySpec.McpServers.Devops.Tools.EnsureEnvironment do
  @moduledoc """
  Create or update a deployment environment row for a project.

  `provisioning_environments` are rows, not an enum — a project starts with
  none and gets `prod`/`uat`/whatever it needs added. `EnvironmentRepository.
  list/1` only seeds the initial `prod`+`uat` pair when a project's row set is
  completely empty, so a project that already has one legacy row (adopted
  before its devops level was set, or left over from an earlier drill) never
  gets a later-needed one created automatically — `permitted_environment_rows/1`
  then filters that lone row out for a devops level it doesn't match, and every
  step that fans out over environments finds none (`402f9439`).

  This is the manual escape hatch: name the environment a project needs and
  it exists, the same shape `ProvisioningLive`'s own environment form writes.
  Host/server/IP are filled in by the domain/server steps as they provision,
  not required here — an empty environment is a valid starting point.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Resources

  schema do
    field :name, :string, required: true, doc: "Environment name, e.g. \"uat\" or \"prod\"."
  end

  @impl true
  def execute(%{name: name} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> EnvironmentRepository.put(name, %{})
      |> reply(name, frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp reply({:ok, _environment}, name, frame), do: {:reply, ok("#{name} environment ready."), frame}
  defp reply({:error, changeset}, _name, frame), do: {:reply, error(changeset), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not ensure the environment: #{inspect(reason)}")
end
