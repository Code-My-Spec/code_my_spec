defmodule CodeMySpec.Provisioning.Credentials do
  @moduledoc """
  Every credential the run will need, and whether each one actually works.

  - **Proven by a call.** `check/3` makes a real, cheap read per credential:
    `:verified` means the provider answered. A token that looks right but is
    read-only would otherwise fail several steps into a run.
  - **Under-scoped is not wrong.** `{:rejected, permission}` names the
    permission the call needed, so the fix is "add Registrar write", not
    "mint another token".
  - **One list** for pasted secrets (Hetzner API token, S3 key pair) and
    account connections (GitHub, Cloudflare, Resend).
  """

  require Logger

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.Integrations
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage}
  alias CodeMySpec.Users.Scope

  @type state :: :verified | :missing | :unchecked | {:rejected, String.t()}

  @type credential :: %{
          key: String.t(),
          label: String.t(),
          kind: :secret | :connection,
          provider: atom(),
          options: [atom()] | :always,
          hint: String.t(),
          directions: String.t(),
          why: String.t()
        }

  # `options: :always` is a credential every run needs. `directions` is separate
  # from `hint`: the hint is a placeholder that disappears once the field has a
  # value, and the directions carry where to go and that a secret is shown once.
  @catalogue [
    %{
      key: "github",
      label: "GitHub",
      kind: :connection,
      provider: :github,
      options: :always,
      hint: "Connected on your account settings",
      directions: "Connect GitHub from your account settings. Setup pushes your project to it.",
      why: "Creates the repository and pushes the code CI builds."
    },
    %{
      key: "hetzner_api_token",
      grain: :account,
      label: "Hetzner API token",
      kind: :secret,
      provider: :hetzner,
      options: :always,
      hint: "Read & Write token from Hetzner Cloud → Security → API tokens",
      directions:
        "Hetzner Cloud console → your project → Security → API tokens → Generate API token. " <>
          "It must be Read & Write; a read-only token passes the first call and fails on the first create. " <>
          "The token is shown once and cannot be read again.",
      why: "Creates the server, its firewall and its SSH key."
    },
    %{
      key: "hetzner_s3_access_key_id",
      label: "Hetzner S3 access key ID",
      kind: :secret,
      provider: :hetzner_s3,
      options: [:storage, :backups],
      hint: "Object Storage → Credentials",
      directions:
        "Hetzner Cloud console → Object Storage → S3 credentials → Generate credentials. " <>
          "There is no API for this — the key pair exists only in the console. " <>
          "The secret half is shown once when the pair is created and cannot be viewed again.",
      why:
        "Creates your buckets. Hetzner issues these in the console only — there is no API for it."
    },
    %{
      key: "hetzner_s3_secret_access_key",
      label: "Hetzner S3 secret access key",
      kind: :secret,
      provider: :hetzner_s3,
      options: [:storage, :backups],
      hint: "Shown once when the key pair is created",
      directions:
        "The other half of the Object Storage → S3 credentials pair, in the same console. " <>
          "It is shown once when the key pair is created and cannot be read again — " <>
          "if you have lost it, generate a new pair rather than looking for it.",
      why: "The other half of the object-storage key pair."
    },
    %{
      key: "cloudflare_token",
      label: "Cloudflare",
      kind: :connection,
      provider: :cloudflare,
      options: [:domain],
      hint: "Connected on your account settings",
      directions:
        "Connect Cloudflare from your account settings. The grant needs Registrar domain admin " <>
          "as well as zone and DNS edit — without Registrar write setup can point a domain but not buy one.",
      why: "Registers the domain and writes the DNS records."
    },
    %{
      key: "resend_token",
      label: "Resend",
      kind: :connection,
      provider: :resend,
      options: [:email, :inbound],
      hint: "Connected on your account settings",
      directions:
        "Connect Resend from your account settings. Setup adds your sending domain to it.",
      why: "Sends mail from your domain and receives replies."
    }
  ]

  @doc """
  Every credential, with what each one is for.

  Ordered as the run needs them, so reading the list top to bottom is reading
  the order things will break in.
  """
  @spec catalogue() :: [credential()]
  def catalogue, do: @catalogue

  @doc """
  The credentials a given set of options actually requires.

  A credential for a step the user turned off is not asked for.
  """
  @spec required(Scope.t() | [atom()]) :: [credential()]
  def required(%Scope{} = scope), do: required(CodeMySpec.Provisioning.setup_options(scope))

  def required(options) when is_list(options) do
    enabled = MapSet.new(options)

    Enum.filter(@catalogue, fn
      %{options: :always} -> true
      %{options: opts} -> Enum.any?(opts, &MapSet.member?(enabled, &1))
    end)
  end

  @doc """
  Whether a credential's value is on file — without reading the value.

  A connection is stored per account by the OAuth flow. A secret is stored at
  the grain its catalogue entry names: `grain: :account` (the Hetzner API
  token, which names a Hetzner account whose boxes outlive any project) reads
  `AccountSecrets`; everything else reads `ProjectSecrets`. `put_value/3` uses
  the same rule, so the form writes where the runtime reads.
  """
  @spec stored?(Scope.t(), credential() | String.t()) :: boolean()
  def stored?(scope, key) when is_binary(key) do
    case Enum.find(@catalogue, &(&1.key == key)) do
      nil -> false
      credential -> stored?(scope, credential)
    end
  end

  def stored?(%Scope{} = scope, %{kind: :secret, grain: :account, key: key}),
    do: AccountSecrets.has_value?(scope, key)

  def stored?(%Scope{} = scope, %{kind: :secret, key: key}),
    do: ProjectSecrets.has_value?(scope, key)

  def stored?(%Scope{} = scope, %{kind: :connection, provider: provider}) do
    match?({:ok, _}, Integrations.fetch_access_token(scope, provider))
  end

  @doc """
  Store a secret at the grain its catalogue entry names.

  The counterpart to `stored?/2`: one function decides the grain for both the
  write and the read.
  """
  @spec put_value(Scope.t(), credential() | String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def put_value(scope, key, value) when is_binary(key) do
    case Enum.find(@catalogue, &(&1.key == key)) do
      nil -> {:error, :unknown_credential}
      credential -> put_value(scope, credential, value)
    end
  end

  def put_value(%Scope{} = scope, %{kind: :secret, grain: :account, key: key}, value),
    do: AccountSecrets.put_value(scope, key, value)

  def put_value(%Scope{} = scope, %{kind: :secret, key: key}, value),
    do: ProjectSecrets.put_value(scope, key, value)

  @doc """
  Prove a credential by using it.

  Returns `:verified`, `:missing`, or `{:rejected, missing_permission}`. The
  call made is the cheapest read each provider offers; a check never
  provisions anything.
  """
  @spec check(Scope.t(), credential() | String.t(), keyword()) :: state()
  def check(scope, key, opts \\ [])

  def check(scope, key, opts) when is_binary(key) do
    case Enum.find(@catalogue, &(&1.key == key)) do
      nil -> :missing
      credential -> check(scope, credential, opts)
    end
  end

  def check(%Scope{} = scope, %{} = credential, opts) do
    if stored?(scope, credential) do
      do_check(scope, credential, opts)
    else
      :missing
    end
  rescue
    # A provider client that raises must not take the page with it: "could not
    # check" is truer than "the page is broken".
    error ->
      Logger.warning("[Credentials] check raised for #{credential.key}: #{inspect(error)}")
      :unchecked
  end

  defp do_check(scope, %{provider: :hetzner}, _opts) do
    classify(Hetzner.list_servers(scope), "Read & Write on Hetzner Cloud")
  end

  defp do_check(scope, %{provider: :hetzner_s3}, opts) do
    case Storage.credentials(scope, opts) do
      :none ->
        :missing

      {:ok, credentials} ->
        credentials
        |> Storage.list_buckets(opts)
        |> classify("Object Storage read on the Hetzner S3 key pair")
    end
  end

  defp do_check(scope, %{provider: :cloudflare}, _opts) do
    # Zones, then the registrar: a grant can read zones and still refuse to buy
    # a domain.
    with :verified <- classify(Cloudflare.list_zones(scope), "Zone read on the Cloudflare grant") do
      classify(Cloudflare.list_domains(scope), "Registrar domain admin on the Cloudflare grant")
    end
  end

  defp do_check(scope, %{provider: :resend}, _opts) do
    classify(Resend.list_domains(scope), "Full access on the Resend grant")
  end

  defp do_check(scope, %{provider: :github}, _opts) do
    case Integrations.fetch_access_token(scope, :github) do
      {:ok, _token} -> :verified
      _ -> :missing
    end
  end

  defp do_check(_scope, _credential, _opts), do: :unchecked

  # A refusal and a network hiccup are different answers: a timeout is
  # `:unchecked`, never `rejected`.
  defp classify({:ok, _}, _permission), do: :verified
  defp classify(:ok, _permission), do: :verified

  # Any provider's `{tag, status, body}` error with 401/403 is a rejection.
  defp classify({:error, {_tag, status, _body}}, permission) when status in [401, 403],
    do: {:rejected, permission}

  defp classify({:error, :unauthorized}, permission), do: {:rejected, permission}
  defp classify({:error, :forbidden}, permission), do: {:rejected, permission}

  defp classify({:error, reason}, _permission) do
    Logger.debug("[Credentials] check inconclusive: #{inspect(reason)}")
    :unchecked
  end

  defp classify(other, _permission) do
    Logger.debug("[Credentials] unexpected check result: #{inspect(other)}")
    :unchecked
  end

  @doc """
  Every required credential that has nothing on file.

  What `start_setup` refuses on: stopping before the first step is the
  difference between "enter your Resend key" and "delete this server and try
  again".
  """
  @spec missing(Scope.t()) :: [credential()]
  def missing(%Scope{} = scope) do
    scope |> required() |> Enum.reject(&stored?(scope, &1))
  end

  @doc """
  The catalogue, each entry carrying whether it is stored and what a check said.

  `check?: false` skips the provider calls; the page renders on mount before
  anything is entered.
  """
  @spec list(Scope.t(), keyword()) :: [map()]
  def list(%Scope{} = scope, opts \\ []) do
    # `check?: true` checks everything; `check: [key, ...]` checks only those,
    # so saving one credential does not call every provider.
    only = Keyword.get(opts, :check)
    check_all? = Keyword.get(opts, :check?, false)

    scope
    |> required()
    |> Enum.map(fn credential ->
      stored = stored?(scope, credential)

      state =
        cond do
          not stored ->
            :missing

          check_all? or (is_list(only) and credential.key in only) ->
            check(scope, credential, opts)

          true ->
            :unchecked
        end

      credential
      |> Map.put(:stored?, stored)
      |> Map.put(:state, state_name(state))
      |> Map.put(:missing_permission, missing_permission(state))
    end)
  end

  defp state_name({:rejected, _}), do: "rejected"
  defp state_name(state), do: to_string(state)

  defp missing_permission({:rejected, permission}), do: permission
  defp missing_permission(_), do: nil

  @doc """
  Whether every credential this project's options require is on file.

  Used by the page to decide whether the run may start at all.
  """
  @spec complete?(Scope.t()) :: boolean()
  def complete?(%Scope{active_project: %Project{}} = scope), do: missing(scope) == []
  def complete?(_), do: false
end
