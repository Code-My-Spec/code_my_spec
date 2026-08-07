defmodule CodeMySpec.ProjectSecrets.ProjectSecretRepository do
  @moduledoc """
  Data access for project credential material.

  Every function takes a `Scope` and derives the project from it, so a
  caller cannot reach outside its own project by passing an id. Scopes
  with no active project fail the function head rather than falling
  through to an unscoped query.
  """

  import Ecto.Query

  alias CodeMySpec.Repo
  alias CodeMySpec.ProjectSecrets.ProjectSecret
  alias CodeMySpec.Users.Scope

  @spec fetch(Scope.t(), String.t(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def fetch(%Scope{active_project_id: project_id}, key, environment)
      when is_binary(project_id) and is_binary(key) and is_binary(environment) do
    ProjectSecret
    |> where([s], s.project_id == ^project_id and s.key == ^key and s.environment == ^environment)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      secret -> {:ok, secret}
    end
  end

  # No project means no project secret — which is an answer, not a crash.
  #
  # A scope without an active project is ordinary: `Resources.report/1` is
  # account-grain by design (a bucket outlives the project that made it, and
  # the SSH key is shared), and it reads storage credentials on the way. With
  # only the guarded clause above, that raised FunctionClauseError from four
  # frames down in `Storage.credentials/2`, naming a repository function rather
  # than the missing project.
  def fetch(%Scope{}, key, environment) when is_binary(key) and is_binary(environment) do
    {:error, :not_found}
  end

  @doc """
  Lists the key/environment pairs a project holds — never the values.

  This is the enumeration an agent is allowed to see.
  """
  @spec list_keys(Scope.t()) :: [%{key: String.t(), environment: String.t()}]
  def list_keys(%Scope{active_project_id: project_id}) when is_binary(project_id) do
    ProjectSecret
    |> where([s], s.project_id == ^project_id)
    |> order_by([s], asc: s.environment, asc: s.key)
    |> select([s], %{key: s.key, environment: s.environment})
    |> Repo.all()
  end

  @doc """
  Writes a secret, replacing any existing value for the same
  project/key/environment.

  Re-running setup must converge rather than accumulate duplicates, so
  this is an upsert keyed on the same tuple the unique index enforces.
  """
  @spec put(Scope.t(), String.t(), binary(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, Ecto.Changeset.t()}
  def put(%Scope{active_project_id: project_id}, key, value, environment)
      when is_binary(project_id) and is_binary(key) and is_binary(environment) do
    attrs = %{key: key, value: value, environment: environment}

    case fetch(%Scope{active_project_id: project_id}, key, environment) do
      {:ok, existing} -> update_secret(existing, attrs, project_id)
      {:error, :not_found} -> insert_secret(attrs, project_id)
    end
  end

  @spec delete(Scope.t(), String.t(), String.t()) ::
          {:ok, ProjectSecret.t()} | {:error, :not_found}
  def delete(%Scope{active_project_id: project_id} = scope, key, environment)
      when is_binary(project_id) do
    with {:ok, secret} <- fetch(scope, key, environment) do
      Repo.delete(secret)
    end
  end

  @spec exists?(Scope.t(), String.t(), String.t()) :: boolean()
  def exists?(%Scope{active_project_id: project_id}, key, environment)
      when is_binary(project_id) do
    ProjectSecret
    |> where([s], s.project_id == ^project_id and s.key == ^key and s.environment == ^environment)
    |> Repo.exists?()
  end

  defp insert_secret(attrs, project_id) do
    %ProjectSecret{}
    |> ProjectSecret.changeset(attrs, project_id)
    |> Repo.insert()
  end

  defp update_secret(secret, attrs, project_id) do
    secret
    |> ProjectSecret.changeset(attrs, project_id)
    |> Repo.update()
  end
end
