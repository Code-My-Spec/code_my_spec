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
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Resources

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, project} <- Validators.devops_project(scope) do
      scope
      |> Resources.project_scope(project)
      |> read()
      |> reply(frame)
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp read(scope) do
    with {:ok, image} <- Registry.image(scope),
         {:ok, credential} <- Registry.credential(scope) do
      {:ok, image, credential}
    end
  end

  defp reply({:ok, image, credential}, frame) do
    text =
      "registry: #{Registry.default_host()}\n" <>
        "image: #{image}\n" <>
        "username: #{credential.username}\n" <>
        "password: #{credential.password}"

    {:reply, ok(text), frame}
  end

  defp reply({:error, reason}, frame), do: {:reply, error(reason), frame}

  defp ok(text), do: Response.tool() |> Response.text(text)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not read the registry credential: #{inspect(reason)}")
end
