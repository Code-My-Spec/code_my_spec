defmodule CodeMySpec.Provisioning.EnvironmentRepository do
  @moduledoc """
  Reads and writes a project's deployment environments.

  Every step that fans out over environments asks here rather than carrying a
  literal. `["prod", "uat"]` used to be hardcoded in seven places, which made
  "add an environment" a seven-file edit and made per-story QA environments
  impossible to express at all.
  """
  import Ecto.Query

  alias CodeMySpec.Provisioning.Environment
  alias CodeMySpec.Repo
  alias CodeMySpec.Users.Scope

  # What a project starts with. Not a special case — the first two rows, which
  # a project is free to add to or remove from. Production takes the apex, so
  # its host has no prefix; everything else is a subdomain of it.
  @initial [
    %{name: "prod", prefix: nil},
    %{name: "uat", prefix: "uat"}
  ]

  @doc """
  A project's environments, creating the initial set the first time.

  Seeding on read rather than at project creation, because provisioning is
  where environments first mean anything and older projects have none.
  """
  @spec list(Scope.t()) :: [Environment.t()]
  def list(%Scope{active_project: %{id: project_id}} = scope) do
    case all(project_id) do
      [] -> seed(scope)
      environments -> environments
    end
  end

  def list(_scope), do: []

  @doc "Just the names, in a stable order — what most steps actually fan out over."
  @spec names(Scope.t()) :: [String.t()]
  def names(scope), do: scope |> list() |> Enum.map(& &1.name)

  @doc "One environment by name, or nil."
  @spec get(Scope.t(), String.t()) :: Environment.t() | nil
  def get(%Scope{active_project: %{id: project_id}}, name) do
    Repo.get_by(Environment, project_id: project_id, name: name)
  end

  def get(_scope, _name), do: nil

  @doc """
  Create or update an environment by name.

  Used by the server step to record where an environment actually lives once
  the box exists, and by the domain step to fill in hosts once the domain is
  known.
  """
  @spec put(Scope.t(), String.t(), map()) :: {:ok, Environment.t()} | {:error, Ecto.Changeset.t()}
  def put(%Scope{active_project: %{id: project_id}}, name, attrs) do
    existing =
      Repo.get_by(Environment, project_id: project_id, name: name) || %Environment{}

    existing
    |> Environment.changeset(Map.merge(attrs, %{name: name, project_id: project_id}))
    |> Repo.insert_or_update()
  end

  @doc """
  Give every environment without a host one derived from the project's domain.

  Hosts are stored rather than computed at use time so that no step has to know
  that production means the apex. This is the one place that rule lives, and it
  only applies to environments that have not been given a host explicitly.
  """
  @spec assign_hosts(Scope.t(), String.t()) :: [Environment.t()]
  def assign_hosts(scope, domain) when is_binary(domain) and domain != "" do
    for environment <- list(scope) do
      case environment.host do
        nil ->
          {:ok, updated} = put(scope, environment.name, %{host: host_for(environment.name, domain)})
          updated

        _ ->
          environment
      end
    end
  end

  def assign_hosts(scope, _domain), do: list(scope)

  defp host_for("prod", domain), do: domain
  defp host_for(name, domain), do: "#{name}.#{domain}"

  defp all(project_id) do
    Repo.all(
      from e in Environment,
        where: e.project_id == ^project_id,
        order_by: [asc: e.inserted_at, asc: e.name]
    )
  end

  defp seed(%Scope{active_project: %{id: project_id} = project}) do
    domain = Map.get(project, :domain)

    for %{name: name, prefix: prefix} <- @initial do
      {:ok, environment} =
        %Environment{}
        |> Environment.changeset(%{
          name: name,
          project_id: project_id,
          host: seed_host(prefix, domain)
        })
        |> Repo.insert()

      environment
    end
  end

  defp seed_host(_prefix, domain) when domain in [nil, ""], do: nil
  defp seed_host(nil, domain), do: domain
  defp seed_host(prefix, domain), do: "#{prefix}.#{domain}"
end
