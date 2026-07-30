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

  `default_firewall_rules/0` opens 80 and 443 to the world and nothing else.
  Story 966's criterion 8004 asserts the database port never answers from
  outside, and the cheapest way to keep that true is to never have a code path
  that opens it — so the public rule set is a fixed list, not a parameter.
  Anything else an environment needs (Postgres, SSH) is reachable over the
  private network or not at all.

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

  # 80 and 443, and deliberately nothing else. See the moduledoc.
  @public_ports ["80", "443"]

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
  `:location` / `:image` / `:firewall_ids` to override individually.
  """
  @spec create_server(Scope.t(), String.t(), keyword()) :: {:ok, body()} | error()
  def create_server(%Scope{} = scope, name, opts \\ []) when is_binary(name) do
    defaults = defaults_for(Keyword.get(opts, :arch, :arm))

    payload =
      %{
        name: name,
        server_type: Keyword.get(opts, :server_type, defaults.server_type),
        location: Keyword.get(opts, :location, defaults.location),
        image: Keyword.get(opts, :image, "ubuntu-24.04"),
        start_after_create: true
      }
      |> maybe_put(:firewalls, firewall_refs(Keyword.get(opts, :firewall_ids)))

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
        {:ok, server}

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
        {:ok, firewall}

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
