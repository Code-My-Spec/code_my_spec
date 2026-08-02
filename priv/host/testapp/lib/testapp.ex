defmodule Testapp.Application do
  @moduledoc """
  The smallest thing that proves the host actually works.

  It reads `DATABASE_URL` from its process environment — which only sops can
  have put there — connects to its own database, and serves the result. So a
  request that answers is evidence of the whole chain: systemd started it,
  sops decrypted its secrets, Postgres let it in, and Caddy proxied to it.

  It also exposes `/read?db=other`, which tries to reach a *different* app's
  database. That is the isolation check from inside the app rather than from a
  shell, and it is the one that matters: a compromised app is a process
  running as that user, not somebody typing `psql`.
  """

  use Application

  def start(_type, _args) do
    port = String.to_integer(System.get_env("PORT", "4000"))
    name = System.get_env("RELEASE_NAME", "app")

    children = [
      {Bandit, plug: {Testapp.Router, name}, port: port}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Testapp.Supervisor)
  end
end

defmodule Testapp.Router do
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(name), do: name

  @impl true
  def call(%Plug.Conn{request_path: "/health"} = conn, name) do
    send_resp(conn, 200, "ok from #{name}")
  end

  def call(%Plug.Conn{request_path: "/"} = conn, name) do
    send_resp(conn, 200, own_database(name))
  end

  # Deliberately reachable: this is how the pen test asks the app itself to
  # cross the boundary, rather than asking a shell to.
  def call(%Plug.Conn{request_path: "/read"} = conn, name) do
    conn = fetch_query_params(conn)
    target = conn.query_params["db"] || name
    send_resp(conn, 200, other_database(target))
  end

  def call(conn, _name), do: send_resp(conn, 404, "not found")

  defp own_database(name) do
    case query(System.get_env("DATABASE_URL"), "select current_database()") do
      {:ok, db} -> "#{name} is up, database=#{db}"
      {:error, reason} -> "#{name} is up, database unreachable: #{reason}"
    end
  end

  defp other_database(target) do
    url = System.get_env("DATABASE_URL") || ""
    # Same credentials, different database — exactly what a compromised app
    # would try.
    swapped = String.replace(url, ~r{/[^/?]+(\?|$)}, "/#{target}\\1")

    case query(swapped, "select current_database()") do
      {:ok, db} -> "REACHED #{db}"
      {:error, reason} -> "REFUSED #{reason}"
    end
  end

  defp query(nil, _sql), do: {:error, "no DATABASE_URL"}

  defp query(url, sql) do
    # Postgrex takes host/user/password/database, not a URL — `:url` is Ecto's
    # doing. Passing one silently yields a config with no host, which fails as
    # a pool timeout rather than as a connection error, and reads like the
    # database being slow rather than absent.
    opts = url |> parse_url() |> Keyword.merge(pool_size: 1, backoff_type: :stop)

    # Trapping exits because `Postgrex.start_link/1` links, and a connection
    # Postgres refuses takes this process down with it — the request 500s and
    # the *reason* never reaches the caller. For a check whose whole job is to
    # report whether the connection was refused, that is the one outcome that
    # must not happen.
    Process.flag(:trap_exit, true)

    with {:ok, pid} <- Postgrex.start_link(opts),
         {:ok, %{rows: [[value]]}} <- Postgrex.query(pid, sql, []) do
      GenServer.stop(pid)
      {:ok, value}
    else
      {:error, %{postgres: %{message: message}}} -> {:error, message}
      {:error, %DBConnection.ConnectionError{message: message}} -> {:error, message}
      {:error, error} when is_exception(error) -> {:error, Exception.message(error)}
      {:error, other} -> {:error, inspect(other)}
    end
  catch
    :exit, {%{postgres: %{message: message}}, _} -> {:error, message}
    :exit, reason -> {:error, "connection refused: #{inspect(reason, limit: 3)}"}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parse_url(url) do
    uri = URI.parse(url)
    [user, password] = String.split(uri.userinfo || ":", ":", parts: 2)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: user,
      password: password,
      database: String.trim_leading(uri.path || "", "/")
    ]
  end
end
