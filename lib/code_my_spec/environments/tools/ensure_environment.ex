defmodule CodeMySpec.Environments.Tools.EnsureEnvironment do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Environments
  alias CodeMySpec.Resources

  @impl true
  def name, do: "ensure_environment"

  @impl true
  def description do
    """
    Create or update a durable environment for this project.
    Choose management "harness" for a destination run by a connected device,
    such as local development, or "provisioned" for a provider-managed deployment,
    such as UAT or production. Defaults to "provisioned" for existing callers.
    An existing environment's management cannot be changed. This does not
    provision infrastructure or start an app. Use list_environments to inspect
    destinations and assign_app_instance_environment to bind an app instance.
    """
  end

  @impl true
  def params do
    %{
      management:
        {:meta, {:enum, ~w(harness provisioned)},
         [description: "How this destination is managed; defaults to provisioned."]},
      name:
        {:required,
         {:meta, :string,
          [description: "Environment name, e.g. \"development\", \"uat\" or \"prod\"."]}}
    }
  end

  @impl true
  def call(%{name: name} = params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> Environments.put(name, %{management: Map.get(params, :management, "provisioned")})
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
