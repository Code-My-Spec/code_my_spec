defmodule CodeMySpec.AppTokens do
  @moduledoc """
  Short-lived tokens a deployed app exchanges its refresh secret for.

  ## What story 971 is actually claiming

  Not "the app holds no long-lived secret" — it holds one, the refresh
  secret, and pretending otherwise would be the kind of security claim that
  is false in a way nobody notices. The honest property is narrower and more
  useful: **what the app holds opens none of the five surfaces.** A refresh
  secret buys a token and nothing else (criterion 8046), so a copy of the
  deployed environment is not a copy of the app's access (8045).

  That is why `verify/1` refuses a refresh secret outright rather than
  treating it as a bearer credential. The two are deliberately not
  interchangeable.

  ## Why Phoenix.Token rather than rows in a table

  A stored token needs issuing, looking up, expiring and reaping, and every
  one of those is a chance for a token to outlive its window because a
  cleanup job did not run. A signed token carries its own expiry: nothing
  issues it a second life, and there is nothing to reap.

  It also answers criterion 8023 exactly. `Phoenix.Token.verify/4`
  distinguishes a token that was valid and aged out from one that was never
  ours — `:expired` versus `:invalid` — which is the difference between "renew
  and retry" and "your credential is wrong, stop retrying". Collapsing them
  into one refusal is how a client ends up hammering a token endpoint over a
  typo.

  ## The refresh secret is found by hash

  Same shape as `deploy_key` / `deploy_key_hash`: the secret itself is stored
  encrypted and useless for lookup, so a digest column carries the lookup.
  Comparing digests rather than plaintext also means the secret is never
  queried against, which keeps it out of query logs.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Projects, CodeMySpec.Repo],
    exports: :all

  import Ecto.Query

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  @salt "app access token"

  # A separate salt, so a socket token cannot be replayed against the REST
  # surfaces and an access token cannot open a socket. They are handed to
  # different holders — the access token stays server-side, the socket token
  # goes to a browser — and a credential that reaches a browser must not be
  # able to do what a server-side one can.
  @socket_salt "widget socket token"

  # Fifteen minutes. Long enough that renewal is not a hot path, short enough
  # that a captured token is a nuisance rather than a breach — criterion 8019
  # asserts the window closes, and a window nobody would notice closing is not
  # one worth having.
  @max_age_seconds 900

  @type refusal :: :expired | :invalid

  @doc """
  Exchange a refresh secret for a short-lived access token.

  Returns `{:ok, token, expires_in}` or `{:error, :invalid}`. There is
  deliberately no third answer: a caller who cannot exchange has exactly one
  thing to check, and telling an unauthenticated caller *why* their secret
  failed tells an attacker the same thing.
  """
  @spec exchange(String.t()) :: {:ok, String.t(), pos_integer()} | {:error, :invalid}
  def exchange(refresh_secret) when is_binary(refresh_secret) and refresh_secret != "" do
    case project_for_refresh_secret(refresh_secret) do
      nil -> {:error, :invalid}
      project -> {:ok, issue(project), @max_age_seconds}
    end
  end

  def exchange(_), do: {:error, :invalid}

  @doc """
  The project a token authenticates, or why it does not.

  `:expired` and `:invalid` are different answers on purpose — see the
  moduledoc.
  """
  @spec verify(String.t(), non_neg_integer()) :: {:ok, Project.t()} | {:error, refusal()}
  def verify(token, max_age \\ @max_age_seconds)

  def verify(token, max_age) when is_binary(token) do
    case Phoenix.Token.verify(secret_base(), @salt, token, max_age: max_age) do
      {:ok, payload} -> project_from(payload)
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify(_, _max_age), do: {:error, :invalid}

  # Tokens issued before the nonce carried a bare id. Accepting both means a
  # token in flight when this deployed does not become invalid mid-request.
  defp project_from({id, _nonce}), do: project_from(id)

  defp project_from(id) when is_binary(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :invalid}
      project -> {:ok, project}
    end
  end

  defp project_from(_), do: {:error, :invalid}

  @doc """
  Mint a socket token for the widget to present from a browser.

  The deploy key authenticates the widget socket today and deliberately never
  reaches the browser — the widget runs in the target app's backend. This is
  the browser-safe equivalent: short-lived, scoped to a socket, useless
  against anything else.
  """
  @spec issue_socket_token(Project.t()) :: {String.t(), pos_integer()}
  def issue_socket_token(%Project{id: id}) do
    {Phoenix.Token.sign(secret_base(), @socket_salt, {id, nonce()}), @max_age_seconds}
  end

  @doc """
  The project a socket token belongs to.

  Same expired/invalid distinction as `verify/1`: a visitor mid-conversation
  whose token aged out needs the socket to re-authenticate in place rather
  than drop (criterion 8055), and that is only possible if "expired" is
  distinguishable from "wrong".
  """
  @spec verify_socket_token(String.t(), non_neg_integer()) ::
          {:ok, Project.t()} | {:error, refusal()}
  def verify_socket_token(token, max_age \\ @max_age_seconds)

  def verify_socket_token(token, max_age) when is_binary(token) do
    case Phoenix.Token.verify(secret_base(), @socket_salt, token, max_age: max_age) do
      {:ok, payload} -> project_from(payload)
      {:error, :expired} -> {:error, :expired}
      {:error, _} -> {:error, :invalid}
    end
  end

  def verify_socket_token(_, _max_age), do: {:error, :invalid}

  @doc "How long an issued token lives, in seconds."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age_seconds

  @doc """
  The digest a refresh secret is looked up by.

  Public because the project changeset writes it and this module reads it;
  one definition means they cannot drift into hashing differently, which
  would fail as "no such secret" rather than as a mismatch.
  """
  @spec hash(String.t()) :: String.t() | nil
  def hash(secret) when is_binary(secret) and secret != "",
    do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  def hash(_), do: nil

  @doc """
  Store a refresh secret's digest against a project.

  The secret itself lives in the project's SOPS-encrypted environment, put
  there by the `callback_credential` provisioning step. Only the digest is
  kept here, and a digest cannot be presented as a credential.
  """
  @spec put_refresh_secret(Project.t(), String.t()) :: {:ok, Project.t()} | {:error, term()}
  def put_refresh_secret(%Project{} = project, refresh_secret) do
    project
    |> Ecto.Changeset.change(cms_refresh_secret_hash: hash(refresh_secret))
    |> Repo.update()
  end

  defp project_for_refresh_secret(refresh_secret) do
    case hash(refresh_secret) do
      nil -> nil
      digest -> Repo.one(from p in Project, where: p.cms_refresh_secret_hash == ^digest)
    end
  end

  # Signed rather than stored, and carrying only the project id plus a nonce.
  #
  # The nonce is not decoration. `Phoenix.Token.sign/4` stamps whole seconds,
  # so two exchanges inside the same second produce byte-identical tokens —
  # and a client that renewed would still be holding the one about to lapse,
  # having been told it was new. Criterion 8020 asserts renewal issues a
  # genuinely different token, and without this it does not.
  #
  # Nothing reads the nonce; its only job is to make each token distinct.
  defp issue(%Project{id: id}) do
    Phoenix.Token.sign(secret_base(), @salt, {id, nonce()})
  end

  defp nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Read from config rather than from the endpoint: a context reaching into
  # the web layer is a dependency the boundary exists to prevent, and the
  # signing key is configuration either way.
  defp secret_base do
    Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:secret_key_base] ||
      raise "no secret_key_base configured — app tokens cannot be signed"
  end
end
