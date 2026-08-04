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

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Users.Scope

  @api_base "https://api.hetzner.cloud/v1"

  @token_key "hetzner_api_token"

  # 22 for the deploy, 80 and 443 for traffic, and deliberately nothing else.
  # Postgres is never on this list. See the moduledoc.
  @public_ports ["22", "80", "443"]

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
    Enum.map(@public_ports, fn port ->
      %{
        direction: "in",
        protocol: "tcp",
        port: port,
        source_ips: ["0.0.0.0/0", "::/0"]
      }
    end)
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
      {:error, {:hetzner_error, 412, _}} = unavailable ->
        # 412 `resource_unavailable` means Hetzner has none of that type in
        # that location right now — a capacity fact about the region, not
        # anything wrong with the request. Hetzner's own message is "error
        # during placement", which tells Sam nothing he can act on.
        #
        # The other architecture is a real answer rather than a workaround:
        # the image is built to match the box (criterion 7975), so the choice
        # is ours to make as long as we record which one we made.
        case fallback_for(arch, opts) do
          nil -> capacity_error(defaults_for(arch), opts)
          other -> retry_elsewhere(scope, name, arch, other, opts, unavailable)
        end

      result ->
        result
    end
  end

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

    request(scope, :post, "/servers", json: payload)
  end

  @doc """
  Return the named server, creating it only if absent.

  This is the idempotent entry point: running the server step twice leaves one
  server, not two.
  """
  @spec ensure_server(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def ensure_server(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    case find_server(scope, name) do
      {:ok, server} ->
        Logger.info("[Hetzner] server #{name} already exists — reusing")
        # Adopted rather than created, so teardown leaves it alone.
        {:ok, Map.put(server, "__adopted__", true)}

      {:error, :not_found} ->
        with {:ok, %{"server" => server}} <- create_server(scope, name, opts), do: {:ok, server}

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
        {:ok, Map.put(firewall, "__adopted__", true)}

      {:error, :not_found} ->
        with {:ok, %{"firewall" => firewall}} <- create_firewall(scope, name),
             do: {:ok, firewall}

      {:error, _} = error ->
        error
    end
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

  defp request(scope, method, path, opts) do
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
  defp token(%Scope{} = scope) do
    case ProjectSecrets.fetch_value(scope, @token_key) do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      _ -> configured_token()
    end
  rescue
    # A scope with no active project cannot carry secrets; fall back rather
    # than crash, so credential checks can run before a project is bound.
    _ -> configured_token()
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
