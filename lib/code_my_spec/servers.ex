defmodule CodeMySpec.Servers do
  @moduledoc """
  Servers an account owns, whether CodeMySpec created them or Sam did.

  ## Why this is not part of Provisioning

  `Provisioning` is project-scoped, and a server there is two denormalised
  strings — `server_name` and `ip` — on a `provisioning_environments` row. That
  grain has three consequences: a box cannot be shared between projects, an
  existing box cannot be adopted, and nothing owns a server's lifecycle. The
  third is the root of the environment-removal and dangling-DNS defects, where
  a destroyed box left a subdomain resolving to a released address.

  Servers belong to the **account**. Linking is a note we make about a box, not
  something we do to it.

  ## The list is the provider's

  `list/1` reports what the provider says right now, merged with what we have
  linked — never our record alone. A box resized in the Hetzner console reads
  correctly here, and one destroyed there is marked `missing` rather than
  quietly dropped, because things still point at it.

  Unlinked servers are returned too. A box nobody can see is a box that keeps
  billing, so linking must never become how a server disappears from view.

  ## Availability, not the catalogue

  `available_options/1` joins `/datacenters` against `/server_types`, because
  only the former says what can be created *now*. During QA every ARM type was
  listed and not deprecated while sold out in all six datacenters. Offering
  from the catalogue means offering something nobody can buy.
  """

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Servers.Server
  alias CodeMySpec.Users.Scope

  @doc """
  Every server the account can see, linked or not.

  Returns `{:error, reason}` when the provider cannot be asked. That is
  deliberately distinct from `{:ok, []}`: an empty list is a claim that the
  account has no servers, and when the truth is "we could not ask", that claim
  is a lie shaped like data.
  """
  @spec list(Scope.t()) :: {:ok, [Server.t()]} | {:error, term()}
  def list(%Scope{} = scope) do
    case reported(scope) do
      {:ok, reported} -> {:ok, merge_with_linked(scope, reported)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Record a server against the account.

  Touches nothing on the machine. Sam's first use of this is on boxes already
  serving traffic, and a link that installed, restarted or reconfigured
  anything would be unusable exactly where it is most wanted.
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

  Arrives already linked: Sam made it here, so asking him to link it
  afterwards would be asking him to confirm something he just did.

  A size the provider cannot supply is returned as an error naming the size
  and where it was tried. Never retried at a different size — a silent
  fallback is how you pay for a machine you did not choose, and if the
  architecture differs, one your images cannot run on.
  """
  @spec provision(Scope.t(), map()) :: {:ok, Server.t()} | {:error, term()}
  def provision(%Scope{} = scope, attrs) do
    case create(scope, attrs) do
      {:ok, created} -> Server.link(scope, normalise(created))
      {:error, reason} -> {:error, reason}
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

    %{
      location: get_in(datacenter, ["location", "name"]) || datacenter["name"],
      city: get_in(datacenter, ["location", "city"]),
      types:
        available
        |> Enum.map(&Map.get(by_id, &1))
        |> Enum.reject(&(is_nil(&1) or &1["deprecated"]))
        |> Enum.map(&describe_type/1)
        |> Enum.sort_by(& &1.hourly)
    }
  end

  defp describe_type(type) do
    %{
      name: type["name"],
      architecture: type["architecture"],
      cores: type["cores"],
      memory: type["memory"],
      disk: type["disk"],
      hourly: hourly_price(type)
    }
  end

  # The gross figure, because that is what Sam is charged. Taking the net one
  # would understate every quote by the VAT he actually pays.
  defp hourly_price(%{"prices" => [%{"price_hourly" => %{"gross" => gross}} | _]}) do
    case Float.parse(to_string(gross)) do
      {value, _} -> Float.round(value, 4)
      :error -> nil
    end
  end

  defp hourly_price(_type), do: nil

  # Injectable so a criterion about how servers are displayed does not have to
  # buy a box to say so. The screen itself is always driven for real.
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

  defp create(scope, attrs) do
    case config(:create) do
      nil -> Hetzner.create_server(scope, attrs[:name] || generated_name(), Enum.to_list(attrs))
      fun -> fun.(scope, attrs)
    end
  end

  defp config(key), do: Application.get_env(:code_my_spec, __MODULE__, [])[key]

  defp generated_name, do: "server-#{System.unique_integer([:positive])}"

  # One shape whether it came from the provider's JSON or a test's map, so
  # nothing downstream has to know which.
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
  # dropped. Anything still pointed at it is now pointed at nothing, and this
  # list is the only place that can say so.
  defp merge_with_linked(scope, reported) do
    linked = Server.linked_names(scope)
    reported_names = MapSet.new(reported, & &1.name)

    present =
      Enum.map(reported, fn server ->
        server
        |> Map.put(:linked, MapSet.member?(linked, server.name))
        |> Map.put(:missing, false)
      end)

    gone =
      linked
      |> Enum.reject(&MapSet.member?(reported_names, &1))
      |> Enum.map(&Server.placeholder/1)

    Enum.sort_by(present ++ gone, &{not &1.linked, &1.name})
  end
end
