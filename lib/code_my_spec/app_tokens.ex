defmodule CodeMySpec.AppTokens do
  @moduledoc """
  Short-lived tokens a deployed app exchanges its refresh secret for.

  The app holds one long-lived secret, the refresh secret, and it opens none
  of the surfaces: it buys a token and nothing else, so `verify/1` refuses it
  as a bearer credential.

  Tokens are signed (`Phoenix.Token`), not stored: each carries its own
  expiry, so there is nothing to reap. `:expired` and `:invalid` stay distinct
  — "renew and retry" versus "your credential is wrong, stop retrying".

  The refresh secret is found by its SHA-256 digest
  (`cms_refresh_secret_hash`), like `deploy_key` / `deploy_key_hash`; the
  plaintext is never queried against.
  """

  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Projects, CodeMySpec.Repo]

  import Ecto.Query

  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo

  @salt "app access token"

  # A separate salt, so a socket token (handed to a browser) cannot be replayed
  # against the REST surfaces, nor an access token open a socket.
  @socket_salt "widget socket token"

  # Fifteen minutes.
  @max_age_seconds 900

  @type refusal :: :expired | :invalid

  @doc """
  Exchange a refresh secret for a short-lived access token.

  Returns `{:ok, token, expires_in}` or `{:error, :invalid}` — deliberately
  no reason, which would tell an attacker the same thing.
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

  # Also accepts a bare-id payload, the shape before the nonce.
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

  The deploy key never reaches the browser — the widget runs in the target
  app's backend. This is the browser-safe equivalent: short-lived, scoped to a
  socket, useless against anything else.
  """
  @spec issue_socket_token(Project.t()) :: {String.t(), pos_integer()}
  def issue_socket_token(%Project{id: id}) do
    {Phoenix.Token.sign(secret_base(), @socket_salt, {id, nonce()}), @max_age_seconds}
  end

  @doc """
  The project a socket token belongs to.

  Same expired/invalid distinction as `verify/1`: a visitor whose token aged
  out re-authenticates the socket in place rather than dropping.
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

  Public so the project changeset and this module share one definition and
  cannot drift into hashing differently.
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

  # The nonce only makes each token distinct: `Phoenix.Token.sign/4` stamps
  # whole seconds, so two exchanges in one second would otherwise be identical
  # and a renewal would hand back the token about to lapse.
  defp issue(%Project{id: id}) do
    Phoenix.Token.sign(secret_base(), @salt, {id, nonce()})
  end

  defp nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # From config, not the endpoint: a context must not depend on the web layer.
  defp secret_base do
    Application.get_env(:code_my_spec, CodeMySpecWeb.Endpoint)[:secret_key_base] ||
      raise "no secret_key_base configured — app tokens cannot be signed"
  end
end
