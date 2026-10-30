defmodule CodeMySpec.Provisioning.Tools.PutSecret do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Provisioning.RepositorySecrets
  alias CodeMySpec.Resources

  @impl true
  def name, do: "put_secret"

  @impl true
  def description,
    do:
      "Encrypt a secret and commit the encrypted environment file to the project's GitHub repository."

  @impl true
  def params do
    %{
      environment:
        {:required, {:meta, :string, [description: "Environment, such as prod or uat."]}},
      key: {:required, {:meta, :string, [description: "Secret name."]}},
      value: {:required, {:meta, :string, [description: "Secret value."]}}
    }
  end

  @impl true
  def call(%{environment: environment, key: key, value: value}, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, project} <- CodeMySpec.Tools.connected_project(scope),
         {:ok, %{commit: commit}} <-
           RepositorySecrets.put(Resources.project_scope(scope, project), environment, key, value) do
      {:ok, "Set #{key} in #{environment} secrets at commit #{commit}."}
    else
      {:error, reason} when is_binary(reason) -> {:error, "Could not set secret: #{reason}"}
      {:error, _} -> {:error, "Could not set secret."}
    end
  end
end
