defmodule CodeMySpec.Provisioning.Tools.ReadRegistryCredential do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Resources

  @impl true
  def name, do: "read_registry_credential"

  @impl true
  def description do
    """
    The self-hosted registry's address, image path, and credential for this
    project.

    `:server` already minted and stored this project's registry credential in
    `ProjectSecrets` (`Registry.credential/1`) the moment it provisioned the
    registry container. A caller with a real checkout this server cannot reach
    — updating a hand-written `config/deploy.yml` to point at the self-hosted
    registry instead of ghcr.io, or logging in to push/pull by hand — needs
    the actual values, not a second credential minted somewhere it could never
    commit a config change to use it.

    ## The address is per environment, not per project

    Two environments can live on two different boxes with two different real
    registry addresses — `Registry.default_host/0`'s "localhost:5000" is only
    ever right for a registry bound to loopback, not true of a shared box's
    container today. `environment` resolves the same way
    `DeployArtifacts`/`ProvisioningLive`'s own generated configs do
    (`Steps.registry_address/3`: this server's own adopted network, never one
    derived from the project's name), so the address is real rather than a
    project-wide placeholder.
    """
  end

  @impl true
  def params do
    %{
      environment:
        {:required,
         {:meta, :string, [description: "Environment name, e.g. \"prod\" or \"uat\"."]}}
    }
  end

  @impl true
  def call(%{environment: environment}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> read(environment)
      |> reply()
    else
      {:error, reason} -> error(reason)
    end
  end

  defp read(scope, environment) do
    with {:ok, host} <- Steps.registry_address(scope, environment),
         {:ok, image} <- Registry.image(scope, registry_host: host),
         {:ok, credential} <- Registry.credential(scope) do
      {:ok, host, image, credential}
    end
  end

  defp reply({:ok, host, image, credential}) do
    text =
      "registry: #{host}\n" <>
        "image: #{image}\n" <>
        "username: #{credential.username}\n" <>
        "password: #{credential.password}"

    ok(text)
  end

  defp reply({:error, :not_provisioned}) do
    text =
      "This environment has no server with a private network yet — run the :server " <>
        "provisioning step first, there is no real registry address to report."

    {:error, text}
  end

  defp reply({:error, reason}), do: error(reason)

  defp ok(text), do: {:ok, text}

  defp error(reason),
    do: {:error, "Could not read the registry credential: #{inspect(reason)}"}
end
