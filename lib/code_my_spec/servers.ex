defmodule CodeMySpec.Servers do
  @moduledoc """
  Servers an account owns, whether CodeMySpec created them or the user did.

  Servers belong to the **account**, not a project, so a box can be shared
  and adopted. Linking is a note we make about a box, not something we do to
  it.

  `list/1` reports what the provider says right now, merged with what we have
  linked: a box destroyed at the provider is marked `missing` rather than
  dropped, and unlinked servers are returned too.

  `available_options/1` joins `/datacenters` against `/server_types`, because
  only the former says what can be created *now*.
  See knowledge/infrastructure, "Servers".
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AccountSecrets,
      CodeMySpec.Projects,
      CodeMySpec.Provisioning.Environment,
      CodeMySpec.Provisioning.EnvironmentRepository,
      CodeMySpec.Provisioning.Hetzner,
      CodeMySpec.Repo,
      CodeMySpec.TempFile,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  import Ecto.Query

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Projects
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.{Environment, EnvironmentRepository, Hetzner}
  alias CodeMySpec.Repo
  alias CodeMySpec.Servers.{Containers, Server}
  alias CodeMySpec.TempFile
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  @access_key_public "server_ssh_public_key"
  @access_key_private "server_ssh_private_key"

  @doc """
  Every server the account can see, linked or not.

  Returns `{:error, reason, linked}` when the provider cannot be asked, where
  `linked` is every server the account has linked, marked `unverified`.

  Three outcomes, not two: an empty list claims no servers, an error alone
  claims we know nothing, and neither is true when the provider is unreachable
  but our link records remain. Their *state* is unknown, hence `unverified`.
  """
  @spec list(Scope.t()) :: {:ok, [Server.t()]} | {:error, term(), [Server.t()]}
  def list(%Scope{} = scope) do
    case reported(scope) do
      {:ok, reported} -> {:ok, merge_with_linked(scope, reported)}
      {:error, reason} -> {:error, reason, unverified_linked(scope)}
    end
  end

  defp unverified_linked(scope) do
    Utils.rescued("Servers.unverified_linked", [], fn ->
      scope
      |> Server.linked_environments()
      |> Enum.sort()
      |> Enum.map(fn {name, environment} ->
        # Not `missing`: the provider told us nothing. The label is ours, so
        # it survives.
        name
        |> Server.placeholder(environment)
        |> Map.put(:missing, false)
        |> Map.put(:unverified, true)
      end)
    end)
  end

  @doc """
  Record a server against the account.

  Touches nothing on the machine: linking is used on boxes already serving
  traffic.
  """
  @spec link(Scope.t(), String.t()) :: {:ok, Server.t()} | {:error, term()}
  def link(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, servers} <- reported(scope),
         %{} = server <- Enum.find(servers, &(&1.name == name)) || {:error, :not_found} do
      Server.link(scope, server)
    end
  end

  @doc """
  Create a server in the account's own provider account.

  Arrives already linked. A size the provider cannot supply is returned as an
  error naming the size and where it was tried — never retried at a different
  size, which could be a machine nobody chose on an architecture the images
  cannot run on.
  """
  @spec provision(Scope.t(), map()) :: {:ok, Server.t()} | {:error, term()}
  def provision(%Scope{} = scope, attrs) do
    case create(scope, attrs) do
      {:ok, created} -> Server.link(scope, normalise(created))
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  One server by name, as the list would show it.

  Built from `list/1` so a single server carries exactly what a row does,
  including `unverified` when the provider could not be asked.
  """
  @spec get(Scope.t(), String.t()) :: {:ok, Server.t()} | {:error, :not_found}
  def get(%Scope{} = scope, name) when is_binary(name) do
    case list(scope) do
      {:ok, servers} -> find(servers, name)
      {:error, _reason, linked} -> find(linked, name)
    end
  end

  defp find(servers, name) do
    case Enum.find(servers, &(&1.name == name)) do
      nil -> {:error, :not_found}
      server -> {:ok, server}
    end
  end

  @doc """
  What is running on a server, read from the server, attributed to projects.

  Each container carries `service` — the name kamal deploys it under — and the
  `project_id` that service belongs to when this account has one.

  Attribution is exact, on the derived service names; a container we cannot
  place keeps `project_id: nil` rather than being guessed at, since a shared
  box legitimately runs things nobody here deployed.
  """
  @spec containers(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def containers(%Scope{} = scope, server) do
    with {:ok, containers} <- Containers.list(scope, server) do
      {:ok, attribute(scope, containers)}
    end
  end

  defp attribute(scope, containers) do
    by_service = services(scope)
    Enum.map(containers, &place(&1, by_service))
  end

  # `<app>` in production and `<app>-<environment>` elsewhere, as the generated
  # `deploy.yml` names the service. Two exact spellings of `<app>`: the
  # project slug and the kebabed module name (`MarketMySpec` ->
  # `market-my-spec`).
  defp services(scope) do
    for project <- Projects.list_projects(scope),
        app <- app_names(project),
        environment <- [nil | environment_names(scope, project)],
        into: %{} do
      {if(environment, do: "#{app}-#{environment}", else: app), project}
    end
  end

  defp app_names(project) do
    [Project.slug(project) | module_app_name(project)] |> Enum.uniq()
  end

  defp module_app_name(%{module_name: module_name}) when is_binary(module_name) do
    [module_name |> Macro.underscore() |> String.replace("_", "-")]
  end

  defp module_app_name(_project), do: []

  # Suggestions, not options: they seed the list, they do not bound it.
  @suggested_environments ["prod", "uat"]

  defp environment_names(%Scope{} = scope, project) do
    Utils.rescued("Servers.environment_names", @suggested_environments, fn ->
      %Scope{scope | active_project: project, active_project_id: project.id}
      |> EnvironmentRepository.names()
    end)
  end

  defp place(container, by_service) do
    service = service_of(container)
    project = Map.get(by_service, service)

    container
    |> Map.put(:service, service)
    |> Map.put(:project_id, project && project.id)
    |> Map.put(:project_name, project && project.name)
  end

  # Kamal names a container `<service>-web-<sha>` (and `..._replaced_<id>`
  # mid-swap); cutting at `-web-` recovers the service from both.
  defp service_of(%{name: name}) when is_binary(name) do
    case String.split(name, "-web-", parts: 2) do
      [service, _rest] -> service
      _ -> name
    end
  end

  defp service_of(_container), do: nil

  @doc """
  Remove the account's link to a server.

  Refused while any project still points at it, which would leave an
  environment naming a link record that no longer exists.
  """
  @spec retire(Scope.t(), String.t()) ::
          :ok | {:error, {:in_use, [String.t()]}} | {:error, :not_found}
  def retire(%Scope{} = scope, name) when is_binary(name) do
    case projects_using(scope, name) do
      [] ->
        delete_linked(scope, name)

      projects ->
        {:error, {:in_use, projects}}
    end
  end

  defp delete_linked(scope, name) do
    case Server.get_linked(scope, name) do
      nil -> {:error, :not_found}
      server -> with {:ok, _} <- Server.delete(server), do: :ok
    end
  end

  @doc """
  The linked record for a name, or nil — what the edit form is built from.
  """
  @spec get_linked(Scope.t(), String.t()) :: Server.t() | nil
  def get_linked(%Scope{} = scope, name) when is_binary(name) do
    Server.get_linked(scope, name)
  end

  @doc """
  Changeset for editing a linked server.
  """
  @spec change_server(Server.t(), map()) :: Ecto.Changeset.t()
  def change_server(%Server{} = server, attrs \\ %{}) do
    Server.environment_changeset(server, attrs)
  end

  @doc """
  Save what a linked server is for.

  A free string, not a fixed set: `prod` is a value here, never a branch (see
  `CodeMySpec.Servers.Server`). Blank clears the label.
  """
  @spec update_server(Server.t(), map()) ::
          {:ok, Server.t()} | {:error, Ecto.Changeset.t()}
  def update_server(%Server{} = server, attrs) do
    Server.update(server, attrs)
  end

  @doc """
  Labels to offer for a server, seeded with what setup currently supports and
  extended by whatever this account already uses.

  Suggestions rather than a fixed set: the field accepts anything, so a
  per-story environment is as valid as `prod`.
  """
  @spec known_environments(Scope.t()) :: [String.t()]
  def known_environments(%Scope{} = scope) do
    Utils.rescued("Servers.known_environments", @suggested_environments, fn ->
      in_use =
        scope
        |> Server.linked_environments()
        |> Map.values()
        |> Enum.reject(&is_nil/1)

      (@suggested_environments ++ Enum.sort(in_use)) |> Enum.uniq()
    end)
  end

  @doc """
  The SSH key a new server gets, uploading one if the account has none.

  `Hetzner.create_server/3` refuses a server without a key (nothing could
  reach it). The key is the account's, and `ensure_ssh_key/3` matches on
  fingerprint, so any project's later deploy run can open the box.
  """
  @spec access_key(Scope.t()) :: {:ok, [integer()]} | {:error, term()}
  def access_key(%Scope{} = scope) do
    case config(:access_key) do
      nil -> ensure_access_key(scope)
      fun -> fun.(scope)
    end
  end

  @doc """
  The account's access key, as the text a human would paste into
  `authorized_keys` on a box CodeMySpec did not create.

  Ensures it exists first; the same key `access_key/1` uploads to Hetzner, so
  adopted and created boxes are reachable by one key. No provider API here
  retrofits a key, so the owner adds this by hand, once per box.
  """
  @spec access_public_key(Scope.t()) :: {:ok, String.t()} | {:error, term()}
  def access_public_key(%Scope{} = scope) do
    with {:ok, _key_ids} <- access_key(scope) do
      account_public_key(scope)
    end
  end

  defp ensure_access_key(scope) do
    with {:ok, public} <- account_public_key(scope),
         {:ok, key} <- Hetzner.ensure_ssh_key(scope, "codemyspec", public) do
      {:ok, [key["id"]]}
    end
  end

  defp account_public_key(scope) do
    case AccountSecrets.fetch_value(scope, @access_key_public) do
      {:ok, public} when is_binary(public) and public != "" -> {:ok, public}
      _ -> generate_access_key(scope)
    end
  end

  defp generate_access_key(scope) do
    dir = TempFile.dir("cms-ssh")
    File.mkdir_p!(dir)
    path = Path.join(dir, "id_ed25519")

    try do
      case System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-C", "codemyspec", "-f", path],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          AccountSecrets.put_value(scope, @access_key_private, File.read!(path))
          public = File.read!(path <> ".pub")
          AccountSecrets.put_value(scope, @access_key_public, public)
          {:ok, public}

        {out, status} ->
          {:error,
           "could not generate an access key (ssh-keygen exit #{status}): #{String.trim(out)}"}
      end
    after
      File.rm_rf(dir)
    end
  end

  @doc """
  What can actually be created, by location.

  Each entry is a location with the server types that location can supply
  today, carrying cores, memory, disk, architecture and hourly price — enough
  to choose with, and enough to state a cost before anything is created.
  """
  @spec available_options(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def available_options(%Scope{} = scope) do
    case config(:options) do
      nil -> fetch_options(scope)
      fun -> fun.(scope)
    end
  end

  defp fetch_options(scope) do
    with {:ok, datacenters} <- Hetzner.list_datacenters(scope),
         {:ok, types} <- Hetzner.list_server_types(scope) do
      by_id = Map.new(types, &{&1["id"], &1})

      options =
        datacenters
        |> Enum.map(&location_options(&1, by_id))
        |> Enum.reject(&(&1.types == []))
        |> Enum.sort_by(& &1.location)

      {:ok, options}
    end
  end

  defp location_options(datacenter, by_id) do
    available = get_in(datacenter, ["server_types", "available"]) || []
    location = get_in(datacenter, ["location", "name"]) || datacenter["name"]

    %{
      location: location,
      city: get_in(datacenter, ["location", "city"]),
      types:
        available
        |> Enum.map(&Map.get(by_id, &1))
        |> Enum.reject(&(is_nil(&1) or &1["deprecated"]))
        |> Enum.map(&describe_type(&1, location))
        |> Enum.sort_by(& &1.hourly)
    }
  end

  defp describe_type(type, location) do
    %{
      name: type["name"],
      architecture: type["architecture"],
      cores: type["cores"],
      memory: type["memory"],
      disk: type["disk"],
      hourly: hourly_price(type, location)
    }
  end

  # Priced for the location being offered: most types are priced per location,
  # and a wrong price is worse than none (the user consents to it).
  defp hourly_price(%{"prices" => prices}, location) when is_list(prices) do
    prices
    |> Enum.find(&(&1["location"] == location))
    |> case do
      %{"price_hourly" => %{"gross" => gross}} ->
        case Float.parse(to_string(gross)) do
          {value, _} -> Float.round(value, 4)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp hourly_price(_type, _location), do: nil

  # Injectable so a test of how servers are displayed need not buy a box.
  defp reported(scope) do
    case config(:list) do
      nil ->
        with {:ok, servers} <- Hetzner.list_servers(scope) do
          {:ok, Enum.map(servers, &normalise/1)}
        end

      fun ->
        with {:ok, servers} <- fun.(scope) do
          {:ok, Enum.map(servers, &normalise/1)}
        end
    end
  end

  # `server_type`, not `size`: Hetzner's cross-architecture fallback stands
  # down only when `:server_type` is present, which `provision/2` promises.
  defp create(scope, attrs) do
    case config(:create) do
      nil ->
        with {:ok, ssh_key_ids} <- access_key(scope) do
          Hetzner.create_server(scope, attrs[:name] || generated_name(),
            server_type: attrs[:size],
            location: attrs[:location],
            ssh_key_ids: ssh_key_ids
          )
        end

      fun ->
        fun.(scope, attrs)
    end
  end

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]

  defp generated_name, do: "server-#{System.unique_integer([:positive])}"

  # One shape whether it came from the provider's JSON or a test's map.
  defp normalise(%{"name" => _} = server) do
    %{
      id: server["id"],
      name: server["name"],
      ip: get_in(server, ["public_net", "ipv4", "ip"]) || server["ip"],
      size: get_in(server, ["server_type", "name"]) || server["size"],
      architecture: get_in(server, ["server_type", "architecture"]),
      location: get_in(server, ["datacenter", "location", "name"]) || server["location"],
      status: server["status"]
    }
  end

  defp normalise(%{name: _} = server), do: server

  defp normalise(%{"server" => server}), do: normalise(server)

  # A linked server the provider no longer reports is kept and marked, never
  # dropped: anything still pointed at it is pointed at nothing.
  defp merge_with_linked(scope, reported) do
    linked = Server.linked_environments(scope)
    reported_names = MapSet.new(reported, & &1.name)

    present =
      Enum.map(reported, fn server ->
        server
        |> Map.put(:linked, Map.has_key?(linked, server.name))
        |> Map.put(:missing, false)
        |> Map.put(:unverified, false)
        |> Map.put(:environment, Map.get(linked, server.name))
      end)

    gone =
      linked
      |> Enum.reject(fn {name, _env} -> MapSet.member?(reported_names, name) end)
      |> Enum.map(fn {name, environment} -> Server.placeholder(name, environment) end)

    Enum.sort_by(present ++ gone, &{not &1.linked, &1.name})
  end

  @doc """
  Names of the projects currently pointed at a server, deduplicated.

  What retiring a server refuses against.
  """
  @spec projects_using(Scope.t(), String.t()) :: [String.t()]
  def projects_using(%Scope{active_account_id: account_id}, server_name)
      when is_binary(account_id) and is_binary(server_name) do
    account_id
    |> environments_on(server_name)
    |> Enum.map(& &1.project.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def projects_using(_scope, _server_name), do: []

  @doc """
  Every `%{project, environment}` of the account pointed at a named server.

  Matches both ways an environment points at a box: `server_name`, written
  back by a successful setup run, and `server_id`, written immediately by
  linking (`EnvironmentRepository.put/3`) before any run.
  """
  @spec environments_on(Ecto.UUID.t(), String.t()) :: [
          %{project: Project.t(), environment: String.t()}
        ]
  def environments_on(account_id, server_name) do
    Environment
    |> join(:inner, [e], p in Project, on: p.id == e.project_id)
    |> select([e, p], %{project: p, environment: e.name})
    |> by_name_or_id(account_id, server_name, server_id_for(account_id, server_name))
    |> Repo.all()
  end

  defp by_name_or_id(query, account_id, server_name, nil) do
    where(query, [e, p], p.account_id == ^account_id and e.server_name == ^server_name)
  end

  defp by_name_or_id(query, account_id, server_name, server_id) do
    where(
      query,
      [e, p],
      p.account_id == ^account_id and
        (e.server_name == ^server_name or e.server_id == ^server_id)
    )
  end

  defp server_id_for(account_id, server_name) do
    Server
    |> where([s], s.account_id == ^account_id and s.name == ^server_name)
    |> select([s], s.id)
    |> Repo.one()
  end
end
