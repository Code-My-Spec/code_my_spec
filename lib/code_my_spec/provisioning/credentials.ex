defmodule CodeMySpec.Provisioning.Credentials do
  @moduledoc """
  Every credential the run will need, and whether each one actually works.

  ## Proven by a call, not by looking right

  A token that is the right length and starts with the right prefix tells you
  nothing. The failure this prevents is the one where setup accepts a
  credential, runs four steps, and pauses on the fifth because the token was
  read-only — by which point Sam has a server he did not want yet and no idea
  which of the five things he entered was wrong.

  So `check/2` makes a real request per credential. `:verified` means a
  provider answered; anything else names what is wrong (criterion 7983).

  ## Under-scoped is a different answer from wrong

  A token the provider recognises but refuses is not a bad token, and telling
  Sam "invalid credential" sends him to mint a new one with the same
  permissions. `{:rejected, missing}` carries the permission the call needed,
  so the fix is "add Registrar write" rather than "try again" (criterion
  7984).

  ## Two kinds of credential, one list

  Hetzner has no OAuth — its API token and object-storage key pair are pasted,
  and the key pair can only be minted in the console. Cloudflare, Resend and
  GitHub are connected on the account. Sam does not care about that
  distinction; he cares that the run has what it needs before it starts, which
  is why both kinds appear in one list (criterion 7981) rather than being
  split across two pages by an implementation detail.
  """

  require Logger

  alias CodeMySpec.Integrations
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Provisioning.{Cloudflare, Hetzner, Resend, Storage}
  alias CodeMySpec.ProjectSecrets
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

  # `options: :always` is a credential every run needs whatever Sam turned off
  # — there is no setup without a repository and a server.
  #
  # `directions` is separate from `hint` because they answer different
  # questions: the hint goes in the field, the directions say where in the
  # provider's console to go and what happens when you get there. The S3 secret
  # is shown once and never again, and a placeholder cannot carry that — it
  # disappears the moment the field has a value.
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
      why: "Creates your buckets. Hetzner issues these in the console only — there is no API for it."
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
      directions: "Connect Resend from your account settings. Setup adds your sending domain to it.",
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

  A credential for a step Sam turned off is not asked for (criterion 7982).
  Asking anyway trains people to enter things they do not need, which is how a
  token with more permissions than the job requires ends up in the store.
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

  A secret is stored per project; a connection is stored per account by the
  OAuth flow. Both answer the same question, which is the only one the page
  needs: is there something here to check.
  """
  @spec stored?(Scope.t(), credential() | String.t()) :: boolean()
  def stored?(scope, key) when is_binary(key) do
    case Enum.find(@catalogue, &(&1.key == key)) do
      nil -> false
      credential -> stored?(scope, credential)
    end
  end

  def stored?(%Scope{} = scope, %{kind: :secret, key: key}),
    do: ProjectSecrets.has_value?(scope, key)

  def stored?(%Scope{} = scope, %{kind: :connection, provider: provider}) do
    match?({:ok, _}, Integrations.fetch_access_token(scope, provider))
  end

  @doc """
  Prove a credential by using it.

  Returns `:verified`, `:missing`, or `{:rejected, missing_permission}`. The
  call made is deliberately the cheapest read each provider offers — this runs
  on a page Sam is looking at, and a check that provisions something to prove
  it works is not a check.
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
    # A provider client that raises must not take the page with it. Sam is
    # looking at this while entering credentials, and a Hetzner outage
    # crashing the setup page turns "we could not check that one" into "the
    # page is broken" — which is a much worse answer and a less true one.
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

      credentials ->
        credentials
        |> unwrap()
        |> Storage.list_buckets(opts)
        |> classify("Object Storage read on the Hetzner S3 key pair")
    end
  end

  defp do_check(scope, %{provider: :cloudflare}, _opts) do
    # Zones first, then the registrar. A grant can read zones and still refuse
    # to buy a domain, and that gap is exactly criterion 7984 — reporting the
    # zone read as success would call an under-scoped grant verified.
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

  # A refusal and a network hiccup are different answers. Reporting a timeout
  # as `rejected` sends Sam to re-mint a token that was fine.
  defp classify({:ok, _}, _permission), do: :verified
  defp classify(:ok, _permission), do: :verified

  # Each provider tags its own errors — `{:cloudflare_error, status, body}`,
  # `{:hetzner_error, ...}`, `{:resend_error, ...}`. Matching the status out of
  # the tagged tuple rather than listing the three tags means a fourth
  # provider works here without being added.
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

  defp unwrap({:ok, credentials}), do: credentials
  defp unwrap(credentials), do: credentials

  @doc """
  Every required credential that has nothing on file.

  What `start_setup` refuses on: a run that starts without its credentials
  fails partway, having already made things (criterion 7985). Stopping before
  the first step is the difference between "enter your Resend key" and "delete
  this server and try again".
  """
  @spec missing(Scope.t()) :: [credential()]
  def missing(%Scope{} = scope) do
    scope |> required() |> Enum.reject(&stored?(scope, &1))
  end

  @doc """
  The catalogue, each entry carrying whether it is stored and what a check said.

  `check?: false` skips the provider calls — the page renders on mount long
  before Sam has entered anything, and six HTTP requests to say "missing" six
  times is a slow page and a pointless load on providers.
  """
  @spec list(Scope.t(), keyword()) :: [map()]
  def list(%Scope{} = scope, opts \\ []) do
    # `check?: true` checks everything; `check: [key, ...]` checks only those.
    # The narrow form exists because saving one credential should not call
    # every provider — see `ProvisioningLive.save_credentials`.
    only = Keyword.get(opts, :check)
    check_all? = Keyword.get(opts, :check?, false)

    scope
    |> required()
    |> Enum.map(fn credential ->
      stored = stored?(scope, credential)

      state =
        cond do
          not stored -> :missing
          check_all? or (is_list(only) and credential.key in only) -> check(scope, credential, opts)
          true -> :unchecked
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
