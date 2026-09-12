defmodule CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredential do
  @moduledoc """
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

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Resources

  schema do
    field :environment, :string,
      required: true,
      doc: "Environment name, e.g. \"prod\" or \"uat\"."
  end

  @impl true
  def execute(%{environment: environment} = params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, params),
         {:ok, project} <- Validators.devops_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> read(environment)
      |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp read(scope, environment) do
    with {:ok, host} <- Steps.registry_address(scope, environment),
         {:ok, image} <- Registry.image(scope, registry_host: host),
         {:ok, credential} <- Registry.credential(scope) do
      {:ok, host, image, credential}
    end
  end

  defp reply({:ok, host, image, credential}, frame) do
    text =
      "registry: #{host}\n" <>
        "image: #{image}\n" <>
        "username: #{credential.username}\n" <>
        "password: #{credential.password}"

    {:reply, ok(text), frame}
  end

  defp reply({:error, :not_provisioned}, frame) do
    text =
      "This environment has no server with a private network yet — run the :server " <>
        "provisioning step first, there is no real registry address to report."

    {:reply, Response.tool() |> Response.error(text), frame}
  end

  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do:
      Response.tool()
      |> Response.error("Could not read the registry credential: #{inspect(reason)}")
end
