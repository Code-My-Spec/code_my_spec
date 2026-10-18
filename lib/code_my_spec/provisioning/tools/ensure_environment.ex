defmodule CodeMySpec.Provisioning.Tools.EnsureEnvironment do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Resources

  @impl true
  def name, do: "ensure_environment"

  @impl true
  def description do
    """
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
  end

  @impl true
  def params do
    %{
      name:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"uat\" or \"prod\"."]}}
    }
  end

  @impl true
  def call(%{name: name}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> EnvironmentRepository.put(name, %{})
      |> reply(name)
    else
      {:error, reason} -> error(reason)
    end
  end

  defp reply({:ok, _environment}, name), do: ok("#{name} environment ready.")
  defp reply({:error, changeset}, _name), do: error(changeset)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not ensure the environment: #{inspect(reason)}"}
end
