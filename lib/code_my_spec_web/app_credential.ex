defmodule CodeMySpecWeb.AppCredential do
  @moduledoc """
  Resolves the project behind a deployed app's Bearer credential.

  ## Two credentials, one deliberately on the way out

  A short-lived access token from `POST /api/token` is tried first; the
  durable deploy key is accepted second. Both work, and that ordering is the
  migration: new callers exchange, deployed callers keep working, and nothing
  has to be redeployed for the endpoints to start honouring tokens.

  Dropping the deploy key here would break every shipped client at once,
  which is not a thing to do as a side effect of adding a token path.

  ## Two shapes, because the five surfaces face two directions

  `framework/issues` and `widget/users` are calls *into* CodeMySpec, and they
  identify the caller — each looks a project up by its deploy key's hash. Those
  use `project/1`.

  `content/sync` and `cms/users` are calls *out* to a deployed app, which
  compares one configured key rather than identifying anybody. Those use
  `token/1`: an access token is accepted, and the controller's existing
  configured-key check still runs when there isn't one. Handing them
  `project/1` would quietly widen them from "the key I was configured with" to
  "any project's deploy key" — a real authorization change dressed up as
  adding a token path.

  ## Why this is not a plug

  These controllers authenticate inside the action rather than in the
  pipeline, because two of them answer differently depending on *why* the
  credential failed — `missing` and `not_configured` are distinct responses
  they already return. A plug that halted would flatten those into one, so
  the credential check stays where the controller can shape its own refusal.
  """

  alias CodeMySpec.AppTokens
  alias CodeMySpec.Projects

  @type refusal :: :missing | :expired | :invalid

  @doc """
  The project a request's Bearer credential names.

  `{:error, :expired}` is preserved rather than folded into `:invalid`,
  because a client holding an aged-out token should renew and retry, and one
  holding a wrong credential should stop.
  """
  @spec project(Plug.Conn.t()) :: {:ok, CodeMySpec.Projects.Project.t()} | {:error, refusal()}
  def project(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> credential] -> resolve(credential, effective_max_age(conn))
      _ -> {:error, :missing}
    end
  end

  defp resolve(credential, max_age) do
    case AppTokens.verify(credential, max_age) do
      {:ok, project} ->
        {:ok, project}

      {:error, :expired} ->
        # An aged-out token is not a deploy key that might still work — it was
        # ours and it lapsed. Falling through would report it as `invalid` and
        # send the client to check its configuration instead of renewing.
        {:error, :expired}

      {:error, :invalid} ->
        case Projects.get_project_by_deploy_key(credential) do
          nil -> {:error, :invalid}
          project -> {:ok, project}
        end
    end
  end

  @doc """
  Like `token/1`, but honours a spex clock-advance header so token expiry can
  be exercised through the real HTTP surface.

  A spex drives this endpoint over HTTP and cannot mint a token in the past,
  so the only way it can test "the window closed" is to tell the server time
  has moved. Advancing the clock by N seconds is equivalent to checking the
  token against a `max_age` reduced by N — Phoenix.Token measures elapsed time
  either way.

  Gated on `:allow_spex_clock`, which is set only in the test config. In every
  other environment the header is ignored, so a real client cannot age out its
  own token early or, worse, extend it.
  """
  @spec token(Plug.Conn.t()) :: {:ok, CodeMySpec.Projects.Project.t()} | {:error, refusal()}
  def token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> credential] -> AppTokens.verify(credential, effective_max_age(conn))
      _ -> {:error, :missing}
    end
  end

  @doc "The project a socket token names, honouring the spex clock (test only)."
  @spec socket_token(Plug.Conn.t(), String.t()) ::
          {:ok, CodeMySpec.Projects.Project.t()} | {:error, refusal()}
  def socket_token(conn, token),
    do: AppTokens.verify_socket_token(token, effective_max_age(conn))

  defp effective_max_age(conn) do
    if Application.get_env(:code_my_spec, :allow_spex_clock, false) do
      advance =
        case Plug.Conn.get_req_header(conn, "x-spex-clock-advance-seconds") do
          [value | _] -> String.to_integer(value)
          _ -> 0
        end

      max(AppTokens.max_age() - advance, 0)
    else
      AppTokens.max_age()
    end
  end
end
