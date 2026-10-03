defmodule CodeMySpec.Observability.Credentials do
  @moduledoc """
  Resolves a project's own ClickHouse connection for one environment.

  Story 1081 (provisioning) is what writes these — per-project-per-environment
  rows in `ProjectSecrets`, the same mechanism already used for the SOPS age
  keys, so there is nothing new to learn to read them back. Until 1081 ships
  for a given project, there is no row, and that is reported as
  `:not_configured` rather than treated as a crash: most projects simply have
  no telemetry yet, which is exactly rule `f2136c8c` ("A project with no
  telemetry set up says so and points at the provisioning step").
  """

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope

  @url_key "CLICKHOUSE_URL"
  @username_key "CLICKHOUSE_USERNAME"
  @password_key "CLICKHOUSE_PASSWORD"

  @doc """
  `{:ok, %{url:, username:, password:}}` for the calling project's telemetry
  in `environment`, or `{:error, :not_configured}` if story 1081 has not
  provisioned it yet.
  """
  @spec resolve(Scope.t(), String.t()) ::
          {:ok, %{url: String.t(), username: String.t(), password: String.t()}}
          | {:error, :not_configured}
  def resolve(%Scope{} = scope, environment) when is_binary(environment) do
    with {:ok, url} <- fetch(scope, @url_key, environment),
         {:ok, username} <- fetch(scope, @username_key, environment),
         {:ok, password} <- fetch(scope, @password_key, environment) do
      {:ok, %{url: url, username: username, password: password}}
    end
  end

  defp fetch(scope, key, environment) do
    case ProjectSecrets.fetch_value(scope, key, environment: environment) do
      {:ok, value} -> {:ok, value}
      {:error, :not_found} -> {:error, :not_configured}
    end
  end
end
