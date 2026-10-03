defmodule CmsHarness.AppInstance.Runner do
  @moduledoc """
  Whatever actually touches the machine on `CmsHarness.AppInstance`'s behalf.

  Same shape as `CodeMySpec.Workspaces.Runner`: the orchestration (does this
  copy need cloning, is it idle, what does a stopped copy report) lives in
  `AppInstance` itself and is worth testing at full speed and determinism;
  shelling out to `just`, `psql`, `pg_dump` and a real OS process is not —
  see the "no live shell-outs in tests" rule this project already enforces
  everywhere else. Configure with:

      config :code_my_spec, CmsHarness.AppInstance, runner: MyRunner

  `CmsHarness.AppInstance.Runner.Local` is production's; test support has a
  scripted double.
  """

  @doc "Whether `root`'s `justfile` declares a recipe named `name`."
  @callback recipe?(root :: String.t(), name :: String.t()) :: boolean()

  @doc "A port nothing on this machine is listening on yet."
  @callback free_port() :: pos_integer()

  @doc "The OTP app name `root`'s `mix.exs` declares, or `nil`."
  @callback app_name(root :: String.t()) :: String.t() | nil

  @doc "Whether `database` already exists on the local Postgres server."
  @callback database_exists?(database :: String.t()) :: boolean()

  @doc "The database name main's own `config/dev.exs` declares, or `nil`."
  @callback main_database_name(root :: String.t()) :: String.t() | nil

  @doc """
  The `{http, https}` ports main's own `config/dev.exs` falls back to, or
  `nil` for the whole pair when `PORT` cannot be resolved at all. Main's app
  cannot be allocated a free port the way every other copy's is — it is the
  one address every bookmark, browser tab and the MCP endpoint already
  point at — so it has to be read off the same file that configures it, the
  same way `main_database_name/1` already does for the database.

  `https` is independently `nil` when the app declares no HTTPS endpoint at
  all — a real, ordinary shape (metric_flow's own `config/dev.exs`, `PORT`
  only), not a malformed config. Treating it as required read that shape as
  no address resolvable at all: `{:cannot_resolve_main_address, root}` for a
  checkout whose `PORT` was right there, because the missing HTTPS half
  failed the whole lookup.
  """
  @callback main_ports(root :: String.t()) ::
              {pos_integer(), pos_integer() | nil} | nil

  @doc "Clone `main_database` into a fresh `database` — dump and restore, not a template."
  @callback clone_database(
              root :: String.t(),
              main_database :: String.t(),
              database :: String.t()
            ) ::
              :ok | {:error, term()}

  @doc "Run `root`'s `seed` recipe, if it declares one. Always succeeds — seeding is optional."
  @callback seed(root :: String.t()) :: :ok

  @doc "Drop `database`. Never called on anything but this feature's own clone."
  @callback drop_database(database :: String.t()) :: :ok

  @doc "The commit `root`'s checkout is on, or `nil`."
  @callback current_commit(root :: String.t()) :: String.t() | nil

  @doc """
  Run `root`'s `after-promote` recipe. Only called once `recipe?/2` has
  already confirmed it exists — a project that declares nothing never
  reaches this.
  """
  @callback run_after_promote(root :: String.t()) :: :ok | {:error, term()}

  @doc """
  Launch `root`'s `serve` recipe, detached, with `PORT`/`HTTPS_PORT`/
  `DATABASE_NAME`/`CMS_MAIN_COPY`/`CMS_TUNNEL_HELD_BY_HARNESS`/`PHX_HOST`
  set and its output redirected to `log_path`.

  `host` is the tunnel's own public hostname — `nil` for a copy holding no
  tunnel, in which case `PHX_HOST` is omitted entirely and the app falls
  back to whatever it already defaults to. Without this, a booting app had
  no way to learn the one address it is actually reachable at: `Endpoint.
  url()` built every link (a login email, an OAuth redirect) against
  whatever `config/dev.exs` happened to hardcode, which drifts the moment
  a copy's real preview address differs from it — observed live, a login
  link pointing at a stale tunnel address a browser could not reach.

  `https_port` is `nil` for a main checkout whose `config/dev.exs` declares
  no HTTPS endpoint at all (see `main_ports/1`) — `HTTPS_PORT` is omitted
  from the launched env entirely in that case, not interpolated as the
  string `"nil"`.

  `main?` tells the booting app whether it is the checkout every bookmark
  already points at. A non-main copy has no business starting its own
  `ClientUtils.CloudflareTunnel` — that GenServer reads main's own hardcoded
  tunnel credentials and hostname straight out of `config/dev.exs`, so every
  copy that started one was a second connector answering for main's tunnel,
  each pointed at whatever local port *this* copy happened to get. Harmless
  only because every copy's config also happened to name the same origin
  main's did; the moment a copy's config named its own port instead,
  Cloudflare would split main's public traffic between the two apps.

  `tunnel_held_by_harness?` is the other half of the same fact
  `CmsHarness.AppInstance.ensure_tunnel/3` acts on: `true` exactly when
  `PreviewTunnel.stored_credentials/1` found a tunnel for this copy, which
  means the harness is about to run — or already runs — the connector for
  it. The launched app reads this and skips its own tunnel child when it is
  set, the same way it already skips one for `main?: false`; a copy whose
  tunnel is still `config/dev.exs`'s hardcoded bootstrap (no DB row) sees
  `false` and keeps running its own, exactly as before this existed. Both
  sides derive the same answer from the same fact — there is no separate
  flag to keep in sync, and no state where both or neither are running one.
  """
  @callback launch(
              root :: String.t(),
              port :: pos_integer(),
              https_port :: pos_integer() | nil,
              database :: String.t(),
              log_path :: String.t(),
              main? :: boolean(),
              tunnel_held_by_harness? :: boolean(),
              host :: String.t() | nil
            ) :: {:ok, os_pid :: pos_integer()} | {:error, term()}

  @doc """
  Run `root`'s `reload` recipe against the app already running on `port`,
  synchronously, with the same `PORT`/`HTTPS_PORT`/`DATABASE_NAME` the launch
  had, appending its output to `log_path`. Only called once `recipe?/2` has
  confirmed the recipe exists. `:ok` on exit 0.
  """
  @callback reload(
              root :: String.t(),
              port :: pos_integer(),
              https_port :: pos_integer() | nil,
              database :: String.t(),
              log_path :: String.t()
            ) :: :ok | {:error, term()}

  @doc "Whether `os_pid` can still be signalled."
  @callback alive?(os_pid :: pos_integer()) :: boolean()

  @doc "What the app on `port` is actually doing — same three states `Workspaces.Runner` uses."
  @callback probe(port :: pos_integer()) :: :serving | :erroring | :down

  @doc "Take the whole process tree rooted at `os_pid` down."
  @callback stop_process(os_pid :: pos_integer()) :: :ok

  @doc """
  The `os_pid` of whatever is listening on `port` right now, or `nil` if
  nothing is. Main's port is fixed, not freshly allocated the way every
  other copy's is, so it can already be held by a process this instance
  never launched and holds no tracked `os_pid` for — the checkout's own
  pre-story-1108 dev server, still running from before the first unified
  restart ever ran against it.
  """
  @callback listener_pid(port :: pos_integer()) :: pos_integer() | nil

  @doc """
  The working directory of `os_pid`, or `nil` if it can't be read (the
  process is already gone, or this platform has no way to ask). Compared
  against a copy's own `root` before that copy's app instance ever adopts
  (kills) whatever it finds holding its port — a match confirms the
  listener is this checkout's own old process; anything else is refused
  rather than assumed and killed.
  """
  @callback process_root(os_pid :: pos_integer()) :: String.t() | nil

  @doc """
  Start a named Cloudflare tunnel for this copy's own credentials, pointed at
  `origin_url`. Unlinked from the caller on purpose (`GenServer.start/1`, not
  `start_link/1`) — `AppInstance` holds the pid it gets back and re-checks
  `Process.alive?/1` on every later call rather than trapping an exit, the
  same reasoning `running?/1` already applies to the app's own OS process:
  a dead tunnel should read as "not running," not crash the process
  supervising it.

  Only ever called for a copy confirmed main, right now, by the server —
  see `CmsHarness.HarnessProjectChannel.put_tunnel/2`'s own comment. Never
  called for a copy sharing another's tunnel (criterion 1586); that hostname
  reaches the shared tunnel through main's own connector, not one of its
  own.
  """
  @callback start_tunnel(
              credentials :: %{
                hostname: String.t(),
                tunnel_id: String.t(),
                tunnel_secret: String.t(),
                account_tag: String.t()
              },
              origin_url :: String.t()
            ) :: {:ok, pid()} | {:error, term()}

  @doc "Stop a tunnel this same runner started. Never fails on an already-dead pid."
  @callback stop_tunnel(pid()) :: :ok

  @spec recipe?(String.t(), String.t()) :: boolean()
  def recipe?(root, name), do: impl().recipe?(root, name)

  @spec free_port() :: pos_integer()
  def free_port, do: impl().free_port()

  @spec app_name(String.t()) :: String.t() | nil
  def app_name(root), do: impl().app_name(root)

  @spec database_exists?(String.t()) :: boolean()
  def database_exists?(database), do: impl().database_exists?(database)

  @spec main_database_name(String.t()) :: String.t() | nil
  def main_database_name(root), do: impl().main_database_name(root)

  @spec main_ports(String.t()) :: {pos_integer(), pos_integer() | nil} | nil
  def main_ports(root), do: impl().main_ports(root)

  @spec clone_database(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clone_database(root, main_database, database),
    do: impl().clone_database(root, main_database, database)

  @spec seed(String.t()) :: :ok
  def seed(root), do: impl().seed(root)

  @spec drop_database(String.t()) :: :ok
  def drop_database(database), do: impl().drop_database(database)

  @spec current_commit(String.t()) :: String.t() | nil
  def current_commit(root), do: impl().current_commit(root)

  @spec run_after_promote(String.t()) :: :ok | {:error, term()}
  def run_after_promote(root), do: impl().run_after_promote(root)

  @spec launch(
          String.t(),
          pos_integer(),
          pos_integer() | nil,
          String.t(),
          String.t(),
          boolean(),
          boolean(),
          String.t() | nil
        ) :: {:ok, pos_integer()} | {:error, term()}
  def launch(
        root,
        port,
        https_port,
        database,
        log_path,
        main?,
        tunnel_held_by_harness?,
        host \\ nil
      ),
      do:
        impl().launch(
          root,
          port,
          https_port,
          database,
          log_path,
          main?,
          tunnel_held_by_harness?,
          host
        )

  @spec reload(String.t(), pos_integer(), pos_integer() | nil, String.t(), String.t()) ::
          :ok | {:error, term()}
  def reload(root, port, https_port, database, log_path),
    do: impl().reload(root, port, https_port, database, log_path)

  @spec alive?(pos_integer()) :: boolean()
  def alive?(os_pid), do: impl().alive?(os_pid)

  @spec probe(pos_integer()) :: :serving | :erroring | :down
  def probe(port), do: impl().probe(port)

  @spec stop_process(pos_integer()) :: :ok
  def stop_process(os_pid), do: impl().stop_process(os_pid)

  @spec listener_pid(pos_integer()) :: pos_integer() | nil
  def listener_pid(port), do: impl().listener_pid(port)

  @spec process_root(pos_integer()) :: String.t() | nil
  def process_root(os_pid), do: impl().process_root(os_pid)

  @spec start_tunnel(map(), String.t()) :: {:ok, pid()} | {:error, term()}
  def start_tunnel(credentials, origin_url), do: impl().start_tunnel(credentials, origin_url)

  @spec stop_tunnel(pid()) :: :ok
  def stop_tunnel(pid), do: impl().stop_tunnel(pid)

  defp impl do
    :code_my_spec
    |> Application.get_env(CmsHarness.AppInstance, [])
    |> Keyword.get(:runner, CmsHarness.AppInstance.Runner.Local)
  end
end
