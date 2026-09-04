defmodule CodeMySpec.Provisioning.Hetzner do
  @moduledoc """
  Servers, firewalls and object storage in the user's own Hetzner account.

  Hand-written Req client — no API-wrapper library, per project convention.

  ## Why there is no OAuth here

  Hetzner offers none. Cloudflare and Resend both have OAuth clients and live
  in `CodeMySpec.Integrations`; Hetzner has only API tokens, so its credential
  is a project-scoped secret in `CodeMySpec.ProjectSecrets` instead. That is
  not a shortcut — it is the whole reason `ProjectSecrets` exists alongside
  `Integrations`.

  Two credentials, and they are different in kind:

    - `hetzner_api_token` — mints servers and firewalls through this API.
    - `hetzner_s3_access_key` / `hetzner_s3_secret_key` — always pasted by
      Sam, because Hetzner exposes no API that creates them. The console is
      the only place they exist, and the secret is shown exactly once.

  ## Only the web ports face the internet

  `default_firewall_rules/0` opens 22, 80 and 443 to the world and nothing
  else. Story 966's criterion 8004 asserts the database port never answers
  from outside, and the cheapest way to keep that true is to never have a code
  path that opens it — so the public rule set is a fixed list, not a
  parameter. Postgres is reachable over the private network or not at all.

  22 is on the list because the deploy runs over it: kamal connects as root to
  the host IP, so a server behind a firewall that drops 22 is a server nothing
  can deploy to. An earlier version left it closed and the whole sequence
  stopped dead at the deploy step — a firewall rule that makes the product
  impossible is not a security control, it is a bug with a good excuse.

  Password authentication is not a concern here, and that is enforced rather
  than assumed: `create_server/3` refuses without `:ssh_key_ids`. Hetzner
  disables root password login for any server created with a key, so the
  refusal is what keeps an internet-facing 22 from being a password-guessing
  target. A server created without a key and reachable on 22 is the one
  combination that must not be possible, so there is no code path to it.

  ## Idempotence

  Setup steps converge rather than duplicating resources, so every `ensure_*`
  function looks for the resource by name first and creates only on absence.
  Re-running a step leaves one of everything (criterion 7965). The `create_*`
  functions are the raw calls underneath and will happily make a second
  server — prefer `ensure_*` from step code.
  """

  require Logger

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope

  @api_base "https://api.hetzner.cloud/v1"

  @token_key "hetzner_api_token"

  # 22 for the deploy, 80 and 443 for traffic, and deliberately nothing else.
  # Postgres is never on this list. See the moduledoc.
  @public_ports ["22", "80", "443"]

  # The registry, reachable only from inside the project's own private network.
  #
  # A cloud firewall filters everything arriving at the server, private traffic
  # included — which is why the builder's push timed out rather than being
  # refused. Nothing listening gives you a refusal; a drop gives you a timeout,
  # and that difference is what said "firewall" rather than "dead container"
  # after a probe proved the registry was up and answering locally.
  #
  # `10.0.0.0/16` is the network `ensure_network/2` creates, so this is open to
  # this project's own machines and nothing else. It is deliberately NOT in
  # `public_ports/0`: that list is what the status page renders as open to the
  # internet, and this is the opposite of that.
  @private_range "10.0.0.0/16"
  @private_ports ["5000"]

  @type body :: map()
  @type error ::
          {:error, :hetzner_not_configured}
          | {:error, {:hetzner_error, integer(), term()}}
          | {:error, term()}

  @doc """
  Inbound rules applied to every provisioned server.

  Only the web ports are open to the internet. Returned as data so a caller
  can render them (the status page lists them as `data-test='firewall-rule'`)
  without re-deriving the policy.
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

  # Two lines, two architectures — matching how the environments are actually
  # placed: arm in Europe because it is cheaper, x86 in the US for production.
  # The image has to match the arch, and the deploy publishes a multi-arch
  # image for exactly this reason.
  #
  # Do NOT reintroduce a `cx*` type here. The whole cx line is retired: the API
  # answers "server type 104 is deprecated" for cx22, and no cx type appears in
  # /server_types at all. Found by calling the live API, not by reading docs.
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
  individually.

  Attaching an SSH key at creation is not optional in practice. A server made
  without one has a root password Hetzner emails to the account owner and
  nothing else — so the deploy step, which has to reach the box to configure
  it, cannot. Provisioning a server nobody can log into is not provisioning a
  server.
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
        try_other_architecture(scope, name, arch, opts, unavailable, this_box_is_not_on_offer?(reason))

      result ->
        result
    end
  end

  # Anything else is the caller's answer, unchanged.
  defp try_other_architecture(_scope, _name, _arch, _opts, error, false), do: error

  defp try_other_architecture(scope, name, arch, opts, unavailable, true) do
    # The other architecture is a real answer rather than a workaround: the
    # image is built to match the box (criterion 7975), so the choice is ours
    # to make as long as we record which one we made.
    case fallback_for(arch, opts) do
      nil -> capacity_error(defaults_for(arch), opts)
      other -> retry_elsewhere(scope, name, arch, other, opts, unavailable)
    end
  end

  # Hetzner says "this box cannot be had here" in two different shapes, and
  # only one of them was being read.
  #
  # 412 `resource_unavailable` is capacity: it has none of that type in that
  # location *right now*. Its message is "error during placement", which tells
  # Sam nothing he can act on.
  #
  # 422 `invalid_input` "unsupported location for server type" is the standing
  # version of the same fact — that pairing does not exist at all, today or
  # ever. Hetzner started answering it for `cax11`/`fsn1`, and because the
  # fallback only matched 412 the run died at the server step with a 422 that
  # reads like a malformed request. Matched on the message rather than the
  # status, because 422 is also what a genuinely bad request gets and that one
  # must not be retried into a different box.
  defp this_box_is_not_on_offer?({:hetzner_error, 412, _}), do: true

  defp this_box_is_not_on_offer?({:hetzner_error, 422, %{"error" => %{"message" => message}}})
       when is_binary(message),
       do: String.contains?(message, "unsupported location for server type")

  defp this_box_is_not_on_offer?(_), do: false

  # What was actually asked for, which is not the same as the defaults: a
  # caller can pin either field. Reporting the default when an override was in
  # play sends the reader looking at a server type nobody requested.
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
    Logger.info("[Hetzner] #{defaults_for(arch).server_type} unavailable — trying #{other.server_type} in #{other.location}")

    case create_in(scope, name, other, opts) do
      {:ok, server} ->
        {:ok, server}

      {:error, {:hetzner_error, 412, _}} ->
        # Both sold out. Say so in terms Sam can act on, rather than passing
        # up a message about placement.
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

  # A caller who pinned `:server_type` has already said which box it wants, and
  # `create_in/4` would re-apply that override to the retry — so "try the other
  # architecture" would resend the identical request and call the result a
  # second shortage. Swapping architecture under a pinned type would be worse
  # still: the image is built to match the box, and the caller chose the box.
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
      # At creation rather than by a later attach, so the box has its private
      # address from first boot. A builder that attaches afterwards has already
      # been told where to push, and the address it was told is the one it does
      # not have yet.
      |> maybe_put(:networks, Keyword.get(opts, :network_ids))

    request(scope, :post, "/servers", json: payload)
  end

  @doc """
  Return the named server, creating it only if absent.

  This is the idempotent entry point: running the server step twice leaves one
  server, not two.

  An adopted server never went through `create_server/3`'s payload, which is
  the only place a firewall or SSH key otherwise gets attached — so adopting
  one used to leave it wide open under our own firewall's rules regardless of
  what `ensure_firewall/2` just ensured. `opts[:firewall_ids]` is attached
  here explicitly to close that gap. The SSH key has no equivalent: Hetzner's
  API has no action that adds a key to a server that already exists, only at
  creation, so a box adopted this way needs the account's key added to its
  `authorized_keys` by hand — one time, by whoever owns the box.
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

  `create_server/3` does this as part of the create payload for a box we made
  ourselves; this is the equivalent for a box `ensure_server/3` found instead
  — the only case that needs a separate call. Setup runs more than once
  though, same reasoning as `attach_to_network/3`: Hetzner answers a repeat
  apply with 422 `firewall_already_applied`, not the no-op these docs used to
  assume — found live against fuellytics-prod, where the box already carried
  the firewall from an earlier run and the whole :server step failed on
  exactly the state `ensure_server/3`'s "idempotent entry point" claim
  requires it not to fail on.
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
  now". `/server_types` lists what exists in the catalogue, which is a
  different question: during QA every ARM type was listed and not deprecated
  while being sold out in all six datacenters (issue 92e0b786). Offering a
  size from the catalogue is how you offer something nobody can buy.

  The `server_types.available` list holds type *ids*, so it is only useful
  joined against `list_server_types/1`.
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

  This is how a step's state is checked against the provider rather than read
  back from our own row — criterion 7970 — and how a server deleted behind
  setup's back shows up as absent so it can be rebuilt rather than skipped
  (criterion 7964).
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

  Read off the provider rather than inferred from what we asked for, because
  `create_server/3` answers a sold-out region by creating the *other*
  architecture. That is a real answer only for as long as whatever builds the
  image is told about it — an image built for the other one passes every check
  we have and then dies at container start.
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

  Hetzner's own create-server flow already returns the new server
  synchronously and readiness is checked by polling SSH directly (see
  `Builder.Remote.await_ssh/4`) rather than a Hetzner action's own status —
  the same shape applies here: the caller polls `list_images/2` for the new
  image to actually appear rather than watching an action id.
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

  # 10.0.0.0/16 with one 10.0.0.0/24 subnet. Hetzner requires a subnet before a
  # server can attach, and a network with no subnet accepts the attach call and
  # then hands out no address — which surfaces as a registry bound to nothing.
  @network_range "10.0.0.0/16"
  @subnet_range "10.0.0.0/24"

  # Which zone a location belongs to. A network's subnet lives in exactly one
  # zone and a server can only reach a subnet in its own — so a subnet in the
  # wrong zone produces a network both machines appear to be on, holding
  # addresses, with no path between them. That is not a theoretical failure: it
  # is what happened. App servers default to `ash` for x86, the builder was
  # pinned to `fsn1`, and the subnet was hardcoded `eu-central`. Both boxes had
  # 10.0.0.x addresses and routes, and ping got 100% loss.
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

  The registry the deploy pulls from listens on this network rather than on a
  public address. Both the app's server and the ephemeral builder attach to it,
  which is what makes one image reference correct in both places: the builder
  pushes to `<private-ip>:5000` and the app pulls from the same string, because
  that address is the app box's own.

  Loopback cannot do that — it is only true on one machine — and a public
  address would put a registry on the internet to solve a problem two machines
  in the same datacenter do not have.
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

  `:network_index` picks the range: 0 (the default) is `10.0.0.0/16`, every
  index after it its own `10.<index>.0.0/16`. A project used to ever create
  exactly one network, so one hardcoded range was the whole project's range.
  A project whose environments span more than one Hetzner zone now creates
  more than one (`Steps.ensure_zone_networks/4`), and Hetzner refuses a
  network whose range overlaps another's in the same project — zone or not.
  Confirmed live against MarketMySpec: its existing network and a freshly
  attempted second one both defaulted to the identical `10.0.0.0/16` and
  Hetzner answered `networks_overlap`. Index 0 always stays the original
  range so every project's existing, already-created network is completely
  unaffected — this only matters for a network being created for the first
  time.
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

  A server can already carry a network no name-based lookup would find —
  `find_network/2`'s caller derives a name from the project asking, and a
  linked server's network belongs to whoever actually made it.
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

  Setup runs more than once, and Hetzner answers a repeat attach with a 409
  `server_already_attached`. Reporting that as failure would make the second
  run of an idempotent step fail, which is the opposite of what re-running is
  for.
  """
  @spec attach_to_network(Scope.t(), integer() | String.t(), integer() | String.t()) ::
          {:ok, :attached | :already_attached} | error()
  def attach_to_network(%Scope{} = scope, server_id, network_id) do
    case request(scope, :post, "/servers/#{server_id}/actions/attach_to_network",
           json: %{network: network_id}
         ) do
      {:ok, _} ->
        {:ok, :attached}

      # Hetzner answers an attach that has already happened with 422
      # `server_already_attached`, not 409 — which made the idempotence here
      # decorative. The server step attaches every box to the baseline
      # network, and the deploy attaches again for a box added later; the
      # second call failed the whole deploy on a condition that is the desired
      # state. Matched on the code as well as the status, because 422 covers
      # plenty of things that are not this.
      {:error, {:hetzner_error, status, %{"error" => %{"code" => "server_already_attached"}}}}
      when status in [409, 422] ->
        {:ok, :already_attached}

      {:error, {:hetzner_error, 409, _}} ->
        {:ok, :already_attached}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The address a server holds on a private network.

  Read back from the server rather than assumed, because Hetzner assigns it —
  the attach call does not say which address it handed out, and guessing the
  next free one in the subnet is how two servers end up believing they share
  an address.
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

  Adopting an existing firewall used to mean keeping whatever rules it already
  had, so a change to the policy never reached a project that had run setup
  before. That is the shape of failure this module's own principle warns
  about — persisted state is a record, not the truth — and it cost a drill:
  the registry port was opened in code, every run adopted a firewall from
  before that change, and the builder's push timed out against a rule set
  nobody had looked at.

  Only written when it differs, so a converged run makes no call.
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

  # Compared on what a rule *is* — direction, protocol, port, sources — rather
  # than on the map, because the API answers with extra keys (`description`,
  # `destination_ips`) that a comparison against our own rules would always
  # find different, making every run rewrite the rules.
  defp same_rules?(current, wanted) do
    MapSet.new(current, &rule_identity/1) == MapSet.new(wanted, &rule_identity/1)
  end

  defp rule_identity(rule) do
    {
      rule["direction"] || rule[:direction],
      rule["protocol"] || rule[:protocol],
      to_string(rule["port"] || rule[:port]),
      MapSet.new(rule["source_ips"] || rule[:source_ips] || [])
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

  Used by the credential-intake step, which proves every credential with a
  real provider call before provisioning starts rather than trusting the
  paste.
  """
  @spec credential_valid?(Scope.t()) :: boolean()
  def credential_valid?(%Scope{} = scope) do
    match?({:ok, _}, list_servers(scope))
  end

  @doc """
  Whether the S3 key pair has been pasted.

  Hetzner mints these only in the console, so there is nothing to call here —
  presence is all that can be checked without attempting a bucket operation.
  """
  @spec s3_credentials_present?(Scope.t()) :: boolean()
  def s3_credentials_present?(%Scope{} = scope) do
    ProjectSecrets.has_value?(scope, "hetzner_s3_access_key") and
      ProjectSecrets.has_value?(scope, "hetzner_s3_secret_key")
  end

  ## Internals

  @doc """
  Return the account's copy of this exact public key, uploading it if absent.

  ## Matched by fingerprint, and that is the whole point

  An earlier version matched by name and reused whatever it found. A project
  re-provisioned with a fresh keypair then got the *old* key attached to its
  new server while setup held the *new* private half, so the server came up
  perfectly and nothing could log into it. The symptom was a silent SSH
  timeout several minutes later, which points nowhere near the cause.

  A fingerprint identifies the key material itself, so this can only ever
  return something the caller can actually authenticate with. When the name is
  already taken by different material, the upload gets a suffixed name rather
  than replacing anything — setup does not destroy resources, and someone
  else's key under a colliding name is exactly the kind of thing that must not
  quietly disappear.
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
        # The name is taken by different material. Suffixing is deliberate:
        # deleting somebody's key to free a name is not setup's business.
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
    with {:ok, %{"ssh_keys" => keys}} <- request(scope, :get, "/ssh_keys?fingerprint=#{print}", []) do
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

  For the leak audit. Keys are easy to leak and easy to miss — they cost
  nothing, so nobody notices seven of them, and each is still a credential a
  recording left behind.
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

  Public so `CodeMySpec.McpServers.Devops.Tools.ProviderRequest` can let an
  agent make ad hoc Hetzner calls without ever holding the token itself —
  the credential is resolved and applied here, same as every other call in
  this module, and never leaves this process.
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

  # Project secret first — that is where a user's own token lives. Application
  # config is the fallback so the platform's own token can drive cassette
  # recording without a project scope.
  # Account first, then the project, then application config.
  #
  # A Hetzner token names one Hetzner account, and the servers it reaches are
  # shared across projects — so the account is where it belongs. The project
  # read stays because installs predating the account grain stored it there,
  # and a caller should not have to know which era it is in. The data
  # migration copies existing tokens up, so the fallback is for stragglers.
  defp token(%Scope{} = scope) do
    with :error <- secret(fn -> AccountSecrets.fetch_value(scope, @token_key) end),
         :error <- secret(fn -> ProjectSecrets.fetch_value(scope, @token_key) end) do
      configured_token()
    end
  end

  # A scope with no active project or account cannot carry secrets. Falling
  # through rather than crashing is what lets credential checks run before
  # either is bound.
  defp secret(read) do
    case read.() do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  rescue
    _ -> :error
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
