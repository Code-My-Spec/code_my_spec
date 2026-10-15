defmodule CodeMySpec.Provisioning.Hetzner do
  @moduledoc """
  Servers, firewalls and object storage in the user's own Hetzner account.

  Hand-written Req client — no API-wrapper library, per project convention.

  - **No OAuth.** Hetzner has only API tokens. `hetzner_api_token` is read
    from `AccountSecrets`, then `ProjectSecrets`, then app config. The S3 key
    pair (`hetzner_s3_access_key_id` / `hetzner_s3_secret_access_key`) is
    always pasted: Hetzner mints it only in the console.
  - **Only 22, 80 and 443 face the internet.** The public rule set is a fixed
    list, not a parameter, so no code path can expose Postgres. 22 is open
    because kamal deploys over it; `create_server/3` refuses without
    `:ssh_key_ids`, and Hetzner disables root password login for a server
    created with a key.
  - **Idempotence.** `ensure_*` finds by name (or fingerprint) and creates
    only on absence; the `create_*` calls underneath do not check. Prefer
    `ensure_*` from step code.

  See knowledge/provisioning, "Hetzner".
  """

  require Logger

  # A leaf: the provider client Servers and Provisioning both call.
  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AccountSecrets,
      CodeMySpec.ProjectSecrets,
      CodeMySpec.Users.Scope,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils.MapAccess

  @api_base "https://api.hetzner.cloud/v1"

  @token_key "hetzner_api_token"

  # 22 for the deploy, 80 and 443 for traffic, and nothing else.
  @public_ports ["22", "80", "443"]

  # The registry port, open only to the private network range. A cloud
  # firewall filters private traffic too (a drop shows as a push timeout).
  # Not in `public_ports/0`, which the status page renders as internet-open.
  @private_range "10.0.0.0/16"
  @private_ports ["5000"]

  @type body :: map()
  @type error ::
          {:error, :hetzner_not_configured}
          | {:error, {:hetzner_error, integer(), term()}}
          | {:error, term()}

  @doc """
  Inbound rules applied to every provisioned server.

  Only the web ports are open to the internet; port 5000 is open to the
  private range. Returned as data so a caller can render them without
  re-deriving the policy.
  """
  @spec default_firewall_rules() :: [map()]
  def default_firewall_rules do
    public =
      Enum.map(@public_ports, fn port ->
        %{
          direction: "in",
          protocol: "tcp",
          port: port,
          source_ips: ["0.0.0.0/0", "::/0"]
        }
      end)

    private =
      Enum.map(@private_ports, fn port ->
        %{
          direction: "in",
          protocol: "tcp",
          port: port,
          source_ips: [@private_range]
        }
      end)

    public ++ private
  end

  @doc "The ports this module will ever open to the internet."
  @spec public_ports() :: [String.t()]
  def public_ports, do: @public_ports

  ## Servers

  # arm in Europe (cheaper), x86 in the US. The image must match the box.
  # Do NOT reintroduce a `cx*` type: the line is retired (the API answers
  # "deprecated", and none appear in /server_types).
  @arm_default %{server_type: "cax11", location: "fsn1"}
  @x86_default %{server_type: "cpx11", location: "ash"}

  @doc """
  Defaults for an architecture — `:arm` (Europe, cheaper) or `:x86` (US).
  """
  @spec defaults_for(:arm | :x86) :: map()
  def defaults_for(:arm), do: @arm_default
  def defaults_for(:x86), do: @x86_default

  @doc """
  Create a server. Prefer `ensure_server/3` — this one does not check first.

  `opts` accepts `:arch` (`:arm`, the default, or `:x86`), and `:server_type` /
  `:location` / `:image` / `:firewall_ids` / `:ssh_key_ids` to override
  individually, and `:labels` to tag the server.

  `:user_data` is Hetzner's cloud-init field, run once on first boot; it is
  logged by size only, since it can carry credentials.

  `:ssh_key_ids` is required (`{:error, :ssh_key_required}` otherwise): a
  server made without a key cannot be reached by setup.

  A sold-out type (412) or an unsupported location/type pairing (422) is
  retried once on the other architecture's defaults, unless `:server_type`
  is pinned.
  """
  @spec create_server(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def create_server(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    case Keyword.get(opts, :ssh_key_ids) do
      nil -> {:error, :ssh_key_required}
      [] -> {:error, :ssh_key_required}
      _ -> do_create_server(scope, name, opts)
    end
  end

  defp do_create_server(scope, name, opts) do
    arch = Keyword.get(opts, :arch, :arm)

    case create_in(scope, name, defaults_for(arch), opts) do
      {:error, reason} = unavailable ->
        try_other_architecture(
          scope,
          name,
          arch,
          opts,
          unavailable,
          this_box_is_not_on_offer?(reason)
        )

      result ->
        result
    end
  end

  # Anything else is the caller's answer, unchanged.
  defp try_other_architecture(_scope, _name, _arch, _opts, error, false), do: error

  defp try_other_architecture(scope, name, arch, opts, unavailable, true) do
    # The other architecture is a real answer: the image is built to match the
    # box, as long as the box's architecture is read back.
    case fallback_for(arch, opts) do
      nil -> capacity_error(defaults_for(arch), opts)
      other -> retry_elsewhere(scope, name, arch, other, opts, unavailable)
    end
  end

  # Two shapes of "not on offer": 412 `resource_unavailable` (no capacity now)
  # and 422 "unsupported location for server type" (never). Matched on the
  # message for 422, which also covers genuinely bad requests that must not be
  # retried.
  defp this_box_is_not_on_offer?({:hetzner_error, 412, _}), do: true

  defp this_box_is_not_on_offer?({:hetzner_error, 422, %{"error" => %{"message" => message}}})
       when is_binary(message),
       do: String.contains?(message, "unsupported location for server type")

  defp this_box_is_not_on_offer?(_), do: false

  # What was actually asked for: a caller can pin either field.
  defp requested(defaults, opts) do
    %{
      server_type: Keyword.get(opts, :server_type, defaults.server_type),
      location: Keyword.get(opts, :location, defaults.location)
    }
  end

  defp capacity_error(defaults, opts) do
    want = requested(defaults, opts)

    {:error,
     {:capacity_unavailable,
      "Hetzner has no #{want.server_type} in #{want.location} right now. This is a capacity " <>
        "shortage at Hetzner, not a problem with your account — try another location or " <>
        "wait and re-run this step."}}
  end

  defp retry_elsewhere(scope, name, arch, other, opts, unavailable) do
    Logger.info(
      "[Hetzner] #{defaults_for(arch).server_type} unavailable — trying #{other.server_type} in #{other.location}"
    )

    case create_in(scope, name, other, opts) do
      {:ok, server} ->
        {:ok, server}

      {:error, {:hetzner_error, 412, _}} ->
        # Both sold out. Say so in terms the user can act on.
        {:error,
         {:capacity_unavailable,
          "Hetzner has no #{defaults_for(arch).server_type} in #{defaults_for(arch).location} " <>
            "or #{other.server_type} in #{other.location} right now. This is a capacity " <>
            "shortage at Hetzner, not a problem with your account — try another location or " <>
            "wait and re-run this step."}}

      _other ->
        unavailable
    end
  end

  # A pinned `:server_type` means no fallback: the retry would resend the same
  # request, and swapping architecture under a chosen box breaks the image.
  defp fallback_for(arch, opts) do
    if Keyword.has_key?(opts, :server_type), do: nil, else: fallback_for(arch)
  end

  defp fallback_for(:arm), do: defaults_for(:x86)
  defp fallback_for(:x86), do: defaults_for(:arm)
  defp fallback_for(_), do: nil

  defp create_in(scope, name, defaults, opts) do
    payload =
      %{
        name: name,
        server_type: Keyword.get(opts, :server_type, defaults.server_type),
        location: Keyword.get(opts, :location, defaults.location),
        image: Keyword.get(opts, :image, "ubuntu-24.04"),
        start_after_create: true
      }
      |> maybe_put(:firewalls, firewall_refs(Keyword.get(opts, :firewall_ids)))
      |> maybe_put(:ssh_keys, Keyword.get(opts, :ssh_key_ids))
      # At creation, so the box has its private address from first boot.
      |> maybe_put(:networks, Keyword.get(opts, :network_ids))
      |> maybe_put(:labels, Keyword.get(opts, :labels))
      # Cloud-init can carry credentials: logged by size, never content.
      |> maybe_put(:user_data, Keyword.get(opts, :user_data))

    log_payload =
      case Map.fetch(payload, :user_data) do
        {:ok, script} -> Map.put(payload, :user_data, "<redacted, #{byte_size(script)} bytes>")
        :error -> payload
      end

    Logger.warning("[Hetzner] create_server payload=#{inspect(log_payload)}")

    request(scope, :post, "/servers", json: payload)
  end

  @doc """
  Return the named server, creating it only if absent.

  This is the idempotent entry point: running the server step twice leaves one
  server, not two. A found server is marked `"__adopted__"`.

  A found server gets `opts[:firewall_ids]` attached explicitly, since only
  `create_server/3`'s payload otherwise attaches one. SSH keys cannot be added
  to an existing server through the API, so an adopted box needs the
  account's key in `authorized_keys` by hand.
  """
  @spec ensure_server(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def ensure_server(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    case find_server(scope, name) do
      {:ok, server} ->
        Logger.info("[Hetzner] server #{name} already exists — reusing")

        with :ok <- attach_firewalls(scope, server["id"], Keyword.get(opts, :firewall_ids, [])) do
          # Adopted rather than created, so teardown leaves it alone.
          {:ok, Map.put(server, "__adopted__", true)}
        end

      {:error, :not_found} ->
        with {:ok, %{"server" => server}} <- create_server(scope, name, opts), do: {:ok, server}

      {:error, _} = error ->
        error
    end
  end

  defp attach_firewalls(_scope, _server_id, []), do: :ok

  defp attach_firewalls(scope, server_id, firewall_ids) do
    Enum.reduce_while(firewall_ids, :ok, fn firewall_id, :ok ->
      case attach_firewall(scope, firewall_id, server_id) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Apply an existing firewall to an existing server, treating "already
  applied" as success.

  The equivalent of `create_server/3`'s firewall payload for a box
  `ensure_server/3` found. Hetzner answers a repeat apply with 422
  `firewall_already_applied`, returned as `{:ok, :already_applied}`.
  """
  @spec attach_firewall(Scope.t(), integer() | String.t(), integer() | String.t()) ::
          {:ok, body() | :already_applied} | error()
  def attach_firewall(%Scope{} = scope, firewall_id, server_id) do
    case request(scope, :post, "/firewalls/#{firewall_id}/actions/apply_to_resources",
           json: %{apply_to: [%{type: "server", server: %{id: server_id}}]}
         ) do
      {:ok, _} = ok ->
        ok

      {:error, {:hetzner_error, 422, %{"error" => %{"code" => "firewall_already_applied"}}}} ->
        {:ok, :already_applied}

      {:error, _} = error ->
        error
    end
  end

  @doc "List every server in the account."
  @spec list_servers(Scope.t()) :: {:ok, [body()]} | error()
  def list_servers(%Scope{} = scope) do
    with {:ok, %{"servers" => servers}} <- request(scope, :get, "/servers", []) do
      {:ok, servers}
    end
  end

  @doc """
  Every datacenter, and which server types each can actually supply today.

  `/datacenters` is the only endpoint that answers "can I create this right
  now"; `/server_types` lists the catalogue, which can show types sold out
  everywhere. `server_types.available` holds type *ids*, so join against
  `list_server_types/1`.
  """
  @spec list_datacenters(Scope.t()) :: {:ok, [body()]} | error()
  def list_datacenters(%Scope{} = scope) do
    with {:ok, %{"datacenters" => datacenters}} <- request(scope, :get, "/datacenters", []) do
      {:ok, datacenters}
    end
  end

  @doc """
  The server type catalogue — cores, memory, disk, architecture and price.

  Says nothing about availability; pair it with `list_datacenters/1`. Asks for
  a full page because the default page size silently truncates the list, and a
  missing type reads as "unavailable" rather than "not fetched".
  """
  @spec list_server_types(Scope.t()) :: {:ok, [body()]} | error()
  def list_server_types(%Scope{} = scope) do
    with {:ok, %{"server_types" => types}} <-
           request(scope, :get, "/server_types?per_page=50", []) do
      {:ok, types}
    end
  end

  @doc """
  Find a server by name.

  How a step's state is checked against the provider rather than our own
  row, and how a server deleted behind setup's back shows up as absent.
  """
  @spec find_server(Scope.t(), String.t()) :: {:ok, body()} | {:error, :not_found} | error()
  def find_server(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, servers} <- list_servers(scope) do
      case Enum.find(servers, &(&1["name"] == name)) do
        nil -> {:error, :not_found}
        server -> {:ok, server}
      end
    end
  end

  @doc """
  The architecture a server actually runs.

  Read off the provider, because `create_server/3` answers a sold-out region
  by creating the *other* architecture, and the image must be built for what
  the box actually is.
  """
  @spec server_architecture(body()) :: {:ok, :arm | :x86} | {:error, term()}
  def server_architecture(%{"server" => server}), do: server_architecture(server)

  def server_architecture(%{"server_type" => %{"architecture" => architecture}}),
    do: architecture(architecture)

  def server_architecture(_server), do: {:error, :no_architecture_reported}

  defp architecture("arm"), do: {:ok, :arm}
  defp architecture("x86"), do: {:ok, :x86}
  defp architecture(other), do: {:error, {:unknown_architecture, other}}

  @doc "Delete a server by id. Used to clean up after recording cassettes."
  @spec delete_server(Scope.t(), integer() | String.t()) :: {:ok, body()} | error()
  def delete_server(%Scope{} = scope, id), do: request(scope, :delete, "/servers/#{id}", [])

  ## Images

  @doc """
  Snapshot a server into a reusable image.

  The caller polls `list_images/2` for the image to become available rather
  than watching an action id.
  """
  @spec create_image(Scope.t(), integer() | String.t(), keyword()) :: {:ok, body()} | error()
  def create_image(%Scope{} = scope, server_id, opts \\ []) do
    body =
      %{type: "snapshot"}
      |> maybe_put(:description, Keyword.get(opts, :description))
      |> maybe_put(:labels, Keyword.get(opts, :labels))

    request(scope, :post, "/servers/#{server_id}/actions/create_image", json: body)
  end

  @doc """
  Images matching a label selector — how a custom builder image is found
  again without storing its id anywhere this account could lose track of.

  `label_selector` is Hetzner's own query syntax (`"key=value"`), the same
  mechanism `create_image/3` writes labels with.
  """
  @spec list_images(Scope.t(), keyword()) :: {:ok, [body()]} | error()
  def list_images(%Scope{} = scope, opts \\ []) do
    query =
      %{}
      |> maybe_put("type", Keyword.get(opts, :type))
      |> maybe_put("label_selector", Keyword.get(opts, :label_selector))
      |> maybe_put("status", Keyword.get(opts, :status))
      |> URI.encode_query()

    with {:ok, %{"images" => images}} <- request(scope, :get, "/images?#{query}", []) do
      {:ok, images}
    end
  end

  ## Private networks

  # 10.0.0.0/16 with one /24 subnet: a network with no subnet accepts the
  # attach and hands out no address.
  @network_range "10.0.0.0/16"
  @subnet_range "10.0.0.0/24"

  # A subnet lives in one zone and a server reaches only subnets in its own:
  # a wrong-zone subnet gives both boxes addresses and no path between them.
  @network_zones %{
    "fsn1" => "eu-central",
    "nbg1" => "eu-central",
    "hel1" => "eu-central",
    "ash" => "us-east",
    "hil" => "us-west",
    "sin" => "ap-southeast"
  }

  @doc "The network zone a location sits in."
  @spec network_zone(String.t()) :: String.t() | nil
  def network_zone(location), do: Map.get(@network_zones, location)

  @doc """
  Return the named private network, creating it only if absent.

  The registry listens on this network, not a public address. The app box and
  the builder both attach, so `<private-ip>:5000` is the same correct image
  reference on both.
  """
  @spec ensure_network(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def ensure_network(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    case find_network(scope, name) do
      {:ok, network} ->
        Logger.info("[Hetzner] network #{name} already exists — reusing")
        {:ok, Map.put(network, "__adopted__", true)}

      {:error, :not_found} ->
        create_network(scope, name, opts)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Create a private network with a subnet servers can attach to.

  `:network_index` picks the range: 0 (the default) is `10.0.0.0/16`, index
  N is `10.N.0.0/16`. Hetzner refuses overlapping ranges within a project, so
  a second zone's network needs its own index; index 0 stays the original
  range so existing networks are unaffected.
  """
  @spec create_network(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def create_network(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    zone = Keyword.get(opts, :network_zone) || "eu-central"
    index = Keyword.get(opts, :network_index, 0)

    payload = %{
      name: name,
      ip_range: network_range(index),
      subnets: [%{type: "cloud", network_zone: zone, ip_range: subnet_range(index)}]
    }

    with {:ok, %{"network" => network}} <- request(scope, :post, "/networks", json: payload) do
      {:ok, network}
    end
  end

  defp network_range(0), do: @network_range
  defp network_range(index) when is_integer(index) and index > 0, do: "10.#{index}.0.0/16"

  defp subnet_range(0), do: @subnet_range
  defp subnet_range(index) when is_integer(index) and index > 0, do: "10.#{index}.0.0/24"

  @doc "List every private network in the account."
  @spec list_networks(Scope.t()) :: {:ok, [body()]} | error()
  def list_networks(%Scope{} = scope) do
    with {:ok, %{"networks" => networks}} <- request(scope, :get, "/networks", []) do
      {:ok, networks}
    end
  end

  @doc "Find a private network by name."
  @spec find_network(Scope.t(), String.t()) :: {:ok, body()} | {:error, :not_found} | error()
  def find_network(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, networks} <- list_networks(scope) do
      case Enum.find(networks, &(&1["name"] == name)) do
        nil -> {:error, :not_found}
        network -> {:ok, network}
      end
    end
  end

  @doc """
  Find a private network by id, as read off a server's own `private_net`.

  A server can carry a network no name-based lookup would find: it belongs to
  whoever made it.
  """
  @spec find_network_by_id(Scope.t(), integer() | String.t()) ::
          {:ok, body()} | {:error, :not_found} | error()
  def find_network_by_id(%Scope{} = scope, id) do
    with {:ok, networks} <- list_networks(scope) do
      case Enum.find(networks, &(to_string(&1["id"]) == to_string(id))) do
        nil -> {:error, :not_found}
        network -> {:ok, network}
      end
    end
  end

  @doc "Delete a private network by id."
  @spec delete_network(Scope.t(), integer() | String.t()) :: {:ok, body()} | error()
  def delete_network(%Scope{} = scope, id), do: request(scope, :delete, "/networks/#{id}", [])

  @doc """
  Attach a server to a private network, treating "already attached" as success.

  Setup runs more than once; Hetzner answers a repeat attach with
  `server_already_attached` (409 or 422), returned as
  `{:ok, :already_attached}`.
  """
  @spec attach_to_network(Scope.t(), integer() | String.t(), integer() | String.t()) ::
          {:ok, :attached | :already_attached} | error()
  def attach_to_network(%Scope{} = scope, server_id, network_id) do
    case request(scope, :post, "/servers/#{server_id}/actions/attach_to_network",
           json: %{network: network_id}
         ) do
      {:ok, _} ->
        {:ok, :attached}

      # 422 covers plenty besides this, so matched on the code too.
      {:error, {:hetzner_error, status, %{"error" => %{"code" => "server_already_attached"}}}}
      when status in [409, 422] ->
        {:ok, :already_attached}

      {:error, {:hetzner_error, 409, _}} ->
        {:ok, :already_attached}

      {:error, _} = error ->
        error
    end
  end

  # credo:disable-for-next-line ExSlop.Check.Readability.NarratorDoc
  @doc """
  The address a server holds on a private network.

  Read back from the server: the attach call does not say which address
  Hetzner assigned.
  """
  @spec private_ip(body(), integer() | String.t()) :: {:ok, String.t()} | {:error, term()}
  def private_ip(%{"server" => server}, network_id), do: private_ip(server, network_id)

  def private_ip(%{"private_net" => nets}, network_id) when is_list(nets) do
    case Enum.find(nets, &(to_string(&1["network"]) == to_string(network_id))) do
      %{"ip" => ip} when is_binary(ip) and ip != "" -> {:ok, ip}
      _ -> {:error, :no_private_address}
    end
  end

  def private_ip(_server, _network_id), do: {:error, :no_private_address}

  ## Firewalls

  @doc "Create a firewall carrying `default_firewall_rules/0`."
  @spec create_firewall(Scope.t(), String.t()) :: {:ok, body()} | error()
  def create_firewall(%Scope{} = scope, name) when is_binary(name) do
    payload = %{name: name, rules: default_firewall_rules()}
    request(scope, :post, "/firewalls", json: payload)
  end

  @doc "Return the named firewall, creating it only if absent."
  @spec ensure_firewall(Scope.t(), String.t()) :: {:ok, body()} | error()
  def ensure_firewall(%Scope{} = scope, name) when is_binary(name) do
    case find_firewall(scope, name) do
      {:ok, firewall} ->
        with {:ok, _} <- reconcile_rules(scope, firewall),
             do: {:ok, Map.put(firewall, "__adopted__", true)}

      {:error, :not_found} ->
        with {:ok, %{"firewall" => firewall}} <- create_firewall(scope, name),
             do: {:ok, firewall}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Replace a firewall's rules with the current policy.

  An adopted firewall keeps old rules otherwise, so a policy change (such as
  opening the registry port) would never reach a project that already ran
  setup. Only written when it differs, so a converged run makes no call.
  """
  @spec reconcile_rules(Scope.t(), body()) :: {:ok, :unchanged | :updated} | error()
  def reconcile_rules(%Scope{} = scope, %{"id" => id} = firewall) do
    wanted = default_firewall_rules()

    if same_rules?(firewall["rules"] || [], wanted) do
      {:ok, :unchanged}
    else
      Logger.info("[Hetzner] firewall #{firewall["name"]} has stale rules — replacing them")

      with {:ok, _} <-
             request(scope, :post, "/firewalls/#{id}/actions/set_rules", json: %{rules: wanted}) do
        {:ok, :updated}
      end
    end
  end

  # Compared on direction, protocol, port and sources: the API adds keys
  # (`description`, `destination_ips`) that would make every run rewrite.
  defp same_rules?(current, wanted) do
    MapSet.new(current, &rule_identity/1) == MapSet.new(wanted, &rule_identity/1)
  end

  defp rule_identity(rule) do
    {
      MapAccess.get(rule, :direction),
      MapAccess.get(rule, :protocol),
      to_string(MapAccess.get(rule, :port)),
      MapSet.new(MapAccess.get(rule, :source_ips, []))
    }
  end

  @doc "List every firewall in the account."
  @spec list_firewalls(Scope.t()) :: {:ok, [body()]} | error()
  def list_firewalls(%Scope{} = scope) do
    with {:ok, %{"firewalls" => firewalls}} <- request(scope, :get, "/firewalls", []) do
      {:ok, firewalls}
    end
  end

  @doc "Find a firewall by name."
  @spec find_firewall(Scope.t(), String.t()) :: {:ok, body()} | {:error, :not_found} | error()
  def find_firewall(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, firewalls} <- list_firewalls(scope) do
      case Enum.find(firewalls, &(&1["name"] == name)) do
        nil -> {:error, :not_found}
        firewall -> {:ok, firewall}
      end
    end
  end

  @doc "Delete a firewall by id."
  @spec delete_firewall(Scope.t(), integer() | String.t()) :: {:ok, body()} | error()
  def delete_firewall(%Scope{} = scope, id), do: request(scope, :delete, "/firewalls/#{id}", [])

  ## Credential checks

  @doc """
  Whether the account is reachable with the stored token.

  Used by the credential-intake step.
  """
  @spec credential_valid?(Scope.t()) :: boolean()
  def credential_valid?(%Scope{} = scope) do
    match?({:ok, _}, list_servers(scope))
  end

  @doc """
  Whether the S3 key pair has been pasted.

  Presence only — there is nothing to call. Checks `hetzner_s3_access_key` /
  `hetzner_s3_secret_key`, which are not the names `Storage.credentials/2`
  reads.
  """
  @spec s3_credentials_present?(Scope.t()) :: boolean()
  def s3_credentials_present?(%Scope{} = scope) do
    ProjectSecrets.has_value?(scope, "hetzner_s3_access_key") and
      ProjectSecrets.has_value?(scope, "hetzner_s3_secret_key")
  end

  ## Internals

  @doc """
  Return the account's copy of this exact public key, uploading it if absent.

  Matched by fingerprint, so this only returns something the caller can
  authenticate with: matching by name once attached an old key to a new
  server. When the name is taken by different material, the upload gets a
  suffixed name rather than replacing anyone's key.
  """
  @spec ensure_ssh_key(Scope.t(), String.t(), String.t()) :: {:ok, body()} | error()
  def ensure_ssh_key(%Scope{} = scope, name, public_key) when is_binary(name) do
    public_key = String.trim(public_key)
    print = fingerprint(public_key)

    case find_ssh_key_by_fingerprint(scope, print) do
      {:ok, key} ->
        Logger.info("[Hetzner] ssh key #{print} already uploaded — reusing")
        {:ok, Map.put(key, "__adopted__", true)}

      {:error, :not_found} ->
        upload_ssh_key(scope, name, public_key, print)

      {:error, _} = error ->
        error
    end
  end

  defp upload_ssh_key(scope, name, public_key, print) do
    case request(scope, :post, "/ssh_keys", json: %{name: name, public_key: public_key}) do
      {:ok, %{"ssh_key" => key}} ->
        {:ok, key}

      {:error, {:hetzner_error, 409, _}} ->
        # The name is taken by different material; never delete someone's key
        # to free a name.
        suffix = print |> String.replace(":", "") |> String.slice(0, 8)

        with {:ok, %{"ssh_key" => key}} <-
               request(scope, :post, "/ssh_keys",
                 json: %{name: "#{name}-#{suffix}", public_key: public_key}
               ),
             do: {:ok, key}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Hetzner's fingerprint for an OpenSSH public key: colon-separated MD5 of the
  decoded blob.

  ## Examples

      iex> CodeMySpec.Provisioning.Hetzner.fingerprint(
      ...>   "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGZoRhKeFsyeaIykmsp/bzMzH0RMp/ltqu7hnsXxPeLp doctest"
      ...> )
      "a1:53:7e:3f:09:2b:7c:2d:61:fa:35:d8:a7:00:1e:71"
  """
  @spec fingerprint(String.t()) :: String.t()
  def fingerprint(public_key) do
    public_key
    |> String.trim()
    |> String.split(~r/\s+/)
    |> Enum.at(1)
    |> Base.decode64!()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(..)(?!$)/, "\\1:")
  end

  @doc "Find an SSH key by its fingerprint."
  @spec find_ssh_key_by_fingerprint(Scope.t(), String.t()) :: {:ok, body()} | error()
  def find_ssh_key_by_fingerprint(%Scope{} = scope, print) when is_binary(print) do
    with {:ok, %{"ssh_keys" => keys}} <-
           request(scope, :get, "/ssh_keys?fingerprint=#{print}", []) do
      case keys do
        [key | _] -> {:ok, key}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "Find an SSH key by name."
  @spec find_ssh_key(Scope.t(), String.t()) :: {:ok, body()} | error()
  def find_ssh_key(%Scope{} = scope, name) when is_binary(name) do
    with {:ok, %{"ssh_keys" => keys}} <- request(scope, :get, "/ssh_keys?name=#{name}", []) do
      case keys do
        [key | _] -> {:ok, key}
        [] -> {:error, :not_found}
      end
    end
  end

  @doc """
  Every SSH key on the account.

  For the leak audit: keys cost nothing, so leaked ones go unnoticed.
  """
  @spec list_ssh_keys(Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def list_ssh_keys(%Scope{} = scope) do
    with {:ok, %{"ssh_keys" => keys}} <- request(scope, :get, "/ssh_keys", []) do
      {:ok, keys}
    end
  end

  @doc "Delete an SSH key. Teardown only; setup never destroys."
  @spec delete_ssh_key(Scope.t(), integer()) :: {:ok, body()} | error()
  def delete_ssh_key(%Scope{} = scope, id) do
    request(scope, :delete, "/ssh_keys/#{id}", [])
  end

  defp firewall_refs(nil), do: nil
  defp firewall_refs([]), do: nil
  defp firewall_refs(ids), do: Enum.map(ids, &%{firewall: &1})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Make an arbitrary authenticated Hetzner API call.

  Public so `CodeMySpec.McpServers.Devops.Tools.ProviderRequest` can make ad
  hoc calls for an agent without the token ever leaving this process.
  """
  @spec request(Scope.t(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def request(scope, method, path, opts) do
    case token(scope) do
      {:ok, token} ->
        [
          method: method,
          url: @api_base <> path,
          headers: [
            {"authorization", "Bearer #{token}"},
            {"content-type", "application/json"}
          ]
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(plug_opt())
        |> Req.request()
        |> handle_response()

      :error ->
        {:error, :hetzner_not_configured}
    end
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp handle_response({:ok, %Req.Response{status: status, body: body}}),
    do: {:error, {:hetzner_error, status, body}}

  defp handle_response({:error, reason}), do: {:error, reason}

  # Account first (a token names a Hetzner account whose servers are shared
  # across projects), then the project (older installs), then app config
  # (platform token for cassette recording).
  defp token(%Scope{} = scope) do
    case AccountSecrets.fetch_account_then_project(scope, @token_key) do
      {:ok, _value} = ok -> ok
      {:error, :not_found} -> configured_token()
    end
  end

  defp configured_token do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:api_token] do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp plug_opt do
    case Application.get_env(:code_my_spec, __MODULE__, [])[:plug] do
      nil -> []
      plug -> [plug: plug]
    end
  end
end
