defmodule CodeMySpec.Environments do
  @moduledoc "Durable project destinations, independently of their running app instances."
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Devices,
      CodeMySpec.Repo,
      CodeMySpec.Requirements.GraphInputs,
      CodeMySpec.Users.Scope
    ],
    exports: :all

  import Ecto.Query
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  @doc "All existing destinations. Reading never creates an environment."
  def list(scope) do
    case project_id(scope) do
      nil ->
        []

      id ->
        Repo.all(
          from e in Environment,
            where: e.project_id == ^id,
            order_by: [asc: e.inserted_at, asc: e.name]
        )
    end
  end

  def list_existing(scope), do: list(scope)

  def list_existing_deployment(scope),
    do: Enum.filter(list(scope), &(&1.management == :provisioned))

  @doc "Deployment destinations, initializing the legacy prod/uat pair when none exists."
  def list_deployment(scope) do
    case project_id(scope) do
      nil ->
        []

      id ->
        {:ok, environments} =
          Repo.transaction(fn ->
            Repo.lock!("environments:#{id}")

            existing_or_seed_deployment(scope, id)
          end)

        environments
    end
  end

  defp existing_or_seed_deployment(scope, project_id) do
    case list_existing_deployment(scope) do
      [] -> seed_deployment(scope, project_id)
      environments -> environments
    end
  end

  def deployment_names(scope), do: Enum.map(list_deployment(scope), & &1.name)

  def get(scope, name), do: fetch(scope, name: name)

  def get_by_id(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> fetch(scope, id: uuid)
      :error -> nil
    end
  end

  def get_deployment(scope, name) do
    case get(scope, name) do
      %Environment{management: :provisioned} = environment -> environment
      _ -> nil
    end
  end

  defp fetch(scope, filters) do
    case project_id(scope) do
      nil -> nil
      id -> Repo.get_by(Environment, [{:project_id, id} | filters])
    end
  end

  @doc "Create or update a destination within the active project. Management is immutable."
  def put(scope, name, attrs) do
    case project_id(scope) do
      nil ->
        {:error, :no_active_project}

      id ->
        existing = get(scope, name) || %Environment{}
        attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
        attrs = Map.merge(attrs, %{"name" => name, "project_id" => id})

        result =
          existing
          |> Environment.changeset(attrs)
          |> validate_device_account(scope)
          |> Repo.insert_or_update()

        if is_nil(existing.id) and match?({:ok, _}, result), do: setup_changed(scope)
        result
    end
  end

  defp validate_device_account(changeset, scope) do
    case Ecto.Changeset.fetch_change(changeset, :device_id) do
      {:ok, id} when is_binary(id) ->
        if CodeMySpec.Devices.get_device(scope, id),
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :device_id, "does not belong to this account")

      _ ->
        changeset
    end
  end

  @doc "Write a provider-managed deployment without repurposing a harness destination."
  def put_deployment(scope, name, attrs) do
    management = Map.get(attrs, :management, Map.get(attrs, "management", :provisioned))

    case {get(scope, name), management} do
      {%Environment{management: :harness}, _} -> {:error, :not_provisioned_environment}
      {_, management} when management in [:provisioned, "provisioned"] -> put(scope, name, attrs)
      _ -> {:error, :not_provisioned_environment}
    end
  end

  @doc "Ensure the local development destination without creating cloud deployment defaults."
  def ensure_development(scope) do
    case project_id(scope) do
      nil ->
        {:error, :no_active_project}

      id ->
        Repo.transaction(fn ->
          Repo.lock!("environments:#{id}")

          Enum.find(list(scope), &development_environment?/1) || create_development(scope)
        end)
    end
  end

  defp development_environment?(%Environment{management: :harness, name: name}) do
    name in ["dev", "dev-local"] or
      Regex.match?(~r/^dev-local-(?:[2-9]|[1-9][0-9]+)$/, name)
  end

  defp development_environment?(_environment), do: false

  defp create_development(scope) do
    case put(scope, development_name(scope), %{management: :harness}) do
      {:ok, environment} -> environment
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp development_name(scope) do
    names = MapSet.new(list(scope), & &1.name)

    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn
      0 -> "dev"
      1 -> "dev-local"
      suffix -> "dev-local-#{suffix}"
    end)
    |> Enum.find(&(not MapSet.member?(names, &1)))
  end

  def mark_first_deployed(scope, name) do
    case get(scope, name) do
      nil ->
        :ok

      environment ->
        now = DateTime.utc_now()

        Repo.update_all(
          from(e in Environment, where: e.id == ^environment.id and is_nil(e.first_deployed_at)),
          set: [first_deployed_at: now, updated_at: now]
        )
    end

    :ok
  end

  @doc "Remove a destination only when no app instance still belongs to it."
  def delete(scope, name) do
    case get(scope, name) do
      nil -> :ok
      environment -> delete_environment(scope, environment)
    end
  end

  defp delete_environment(scope, environment) do
    # A table query keeps ownership validation independent of AppInstances,
    # which depends on this context when assigning an instance's destination.
    if Repo.exists?(
         from i in "app_instances", where: i.environment_id == type(^environment.id, :binary_id)
       ) do
      {:error, :environment_in_use}
    else
      changeset = Ecto.Changeset.change(environment)

      changeset =
        Ecto.Changeset.foreign_key_constraint(changeset, :id,
          name: :app_instances_environment_id_fkey
        )

      case Repo.delete(changeset) do
        {:ok, _} -> setup_changed(scope)
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def assign_deployment_hosts(scope, domain) when is_binary(domain) and domain != "" do
    Enum.map(list_deployment(scope), fn
      %Environment{host: nil} = environment ->
        host = if environment.name == "prod", do: domain, else: "#{environment.name}.#{domain}"
        {:ok, updated} = put(scope, environment.name, %{host: host})
        updated

      environment ->
        environment
    end)
  end

  def assign_deployment_hosts(scope, _domain), do: list_deployment(scope)

  defp seed_deployment(scope, project_id) do
    domain =
      case scope do
        %Scope{active_project: %{id: ^project_id, domain: domain}} -> domain
        _ -> nil
      end

    now = DateTime.utc_now()

    rows =
      for name <- ["prod", "uat"] do
        %{
          id: Ecto.UUID.generate(),
          name: name,
          management: :provisioned,
          project_id: project_id,
          host: seed_host(name, domain),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Environment, rows,
      on_conflict: :nothing,
      conflict_target: [:project_id, :name]
    )

    list_existing_deployment(scope)
  end

  defp seed_host(_name, domain) when domain in [nil, ""], do: nil
  defp seed_host("prod", domain), do: domain
  defp seed_host(name, domain), do: "#{name}.#{domain}"

  def setup_changed(scope) do
    case project_id(scope) do
      nil ->
        :ok

      id ->
        GraphInputs.event(
          %{scope | active_project_id: id},
          "Provisioning",
          "devops_setup_changed",
          %{},
          [],
          :project_wide
        )
    end
  end

  defp project_id(%Scope{active_project_id: id}) when is_binary(id), do: id
  defp project_id(%Scope{active_project: %{id: id}}) when is_binary(id), do: id
  defp project_id(_), do: nil
end
