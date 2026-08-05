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

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Servers.{Containers, Server}
  alias CodeMySpec.Users.Scope

  @access_key_public "server_ssh_public_key"
  @access_key_private "server_ssh_private_key"

  @doc """
  Every server the account can see, linked or not.

  Returns `{:error, reason, linked}` when the provider cannot be asked, where
  `linked` is every server the account has linked, marked `unverified`.

  Three outcomes, not two, because there are three facts to tell apart. An
  empty list claims the account has no servers. An error alone claims we know
  nothing. Neither is true when the provider is unreachable but we still hold
  our own link records — those are ours, they need no provider call, and
  dropping them is how a box the account is paying for leaves the screen.

  What we cannot vouch for under an error is the *state* — size, address,
  whether it is still running. Hence `unverified` rather than a size we last
  saw and a status we are guessing at.
  """
  @spec list(Scope.t()) :: {:ok, [Server.t()]} | {:error, term(), [Server.t()]}
  def list(%Scope{} = scope) do
    case reported(scope) do
      {:ok, reported} -> {:ok, merge_with_linked(scope, reported)}
      {:error, reason} -> {:error, reason, unverified_linked(scope)}
    end
  end

  defp unverified_linked(scope) do
    scope
    |> Server.linked_environments()
    |> Enum.sort()
    |> Enum.map(fn {name, environment} ->
      # Not `missing` — that is a claim the provider told us it is gone, and
      # here the provider told us nothing at all. The label survives either
      # way: it is ours, not the provider's, so it is the one thing we can
      # still say for certain.
      name
      |> Server.placeholder(environment)
      |> Map.put(:missing, false)
      |> Map.put(:unverified, true)
    end)
  rescue
    # No account on the scope means no link records to salvage. The caller
    # still gets its error; it just has nothing to show alongside it.
    _ -> []
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
  One server by name, as the list would show it.

  Built from `list/1` so a single server carries exactly what a row does —
  including `unverified` when the provider could not be asked, which is how a
  box still appears on its own page during an outage instead of 404ing.
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
  What is running on a server, read from the server.
  """
  @spec containers(Scope.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def containers(%Scope{} = scope, server) do
    Containers.list(scope, server)
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

  A free string, not a fixed set. `prod` is a value here, never a branch — see
  `CodeMySpec.Servers.Server` for why an enum would undo what
  `provisioning_environments` was built to fix. Blank clears the label, which
  is a real answer: nobody has said what this box is for yet.
  """
  @spec update_server(Server.t(), map()) ::
          {:ok, Server.t()} | {:error, Ecto.Changeset.t()}
  def update_server(%Server{} = server, attrs) do
    Server.update(server, attrs)
  end

  # What setup builds today, offered so the common answer is one click rather
  # than something to spell. Suggestions, not options: they seed the list, they
  # do not bound it, and nothing downstream branches on either value.
  @suggested_environments ["prod", "uat"]

  @doc """
  Labels to offer for a server, seeded with what setup currently supports and
  extended by whatever this account already uses.

  Suggestions rather than a fixed set — the field accepts anything, so
  `qa-story-812` is as valid as `prod`. If it were an enum this list would be
  the whole world, and a per-story environment would be unrepresentable.
  """
  @spec known_environments(Scope.t()) :: [String.t()]
  def known_environments(%Scope{} = scope) do
    in_use =
      scope
      |> Server.linked_environments()
      |> Map.values()
      |> Enum.reject(&is_nil/1)

    (@suggested_environments ++ Enum.sort(in_use)) |> Enum.uniq()
  rescue
    _ -> @suggested_environments
  end

  @doc """
  The SSH key a new server gets, uploading one if the account has none.

  Creating a server without a key is refused by `Hetzner.create_server/3`, and
  rightly: the box would have only a root password Hetzner mails to the account
  owner, so nothing could reach it afterwards.

  The key is the account's, not the project's, and `ensure_ssh_key/3` matches
  on fingerprint — so the box created here is the same box a later deploy run
  can open, whichever project that run belongs to.
  """
  @spec access_key(Scope.t()) :: {:ok, [integer()]} | {:error, term()}
  def access_key(%Scope{} = scope) do
    case config(:access_key) do
      nil -> ensure_access_key(scope)
      fun -> fun.(scope)
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
    dir = Path.join(System.tmp_dir!(), "cms-ssh-#{System.unique_integer([:positive])}")
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
          {:error, "could not generate an access key (ssh-keygen exit #{status}): #{String.trim(out)}"}
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

  # Priced for the location being offered, not whichever one Hetzner happened
  # to list first. 17 of the 25 current types are priced per location, with a
  # spread up to 272% — taking the head quoted Singapore's cpx42 at Falkenstein
  # rates, understating it by 34%. A wrong price is worse than none: Sam
  # consents to a figure the invoice will not match and has no reason to check.
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

  # `server_type`, not `size`. `Hetzner.create_in/4` reads `:server_type`, so
  # passing `:size` silently dropped the size Sam chose, fell back to the ARM
  # default — available in none of the six datacenters — and, because
  # `fallback_for/2` only stands down when `:server_type` is present, armed the
  # cross-architecture retry this function's docs promise never happens.
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
end
