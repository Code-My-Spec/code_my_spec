defmodule CmsHarness.AppInstance.Runner do
  @moduledoc """
  Whatever actually touches the machine on `CmsHarness.AppInstance`'s behalf.

  Same shape as `CodeMySpec.Workspaces.Runner`: orchestration lives in
  `AppInstance` and is tested at full speed; shelling out to `just`, `psql`,
  `pg_dump` and real OS processes lives behind this behaviour, so tests never
  shell out. Configure with:

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
  `nil` for the whole pair when `PORT` cannot be resolved. Main keeps the
  address everything already points at, so it is read off the file that
  configures it.

  `https` is independently `nil` when the app declares no HTTPS endpoint — an
  ordinary shape, not a malformed config.
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
  @callback drop_database(database :: String.t()) :: :ok | {:error, term()}

  @doc "The commit `root`'s checkout is on, or `nil`."
  @callback current_commit(root :: String.t()) :: String.t() | nil

  @doc "The paths that differ between two commits of `root`, or `nil` if git cannot say."
  @callback changed_paths(root :: String.t(), from :: String.t(), to :: String.t()) ::
              [String.t()] | nil

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

  `host` is the tunnel's public hostname, set as `PHX_HOST` so `Endpoint.url()`
  builds links against the address the app is reachable at; omitted when
  `nil`. `HTTPS_PORT` is likewise omitted when `https_port` is `nil`.

  `main?` (`CMS_MAIN_COPY`): a non-main app must not start its own
  `ClientUtils.CloudflareTunnel`, which would answer for main's tunnel.
  `tunnel_held_by_harness?` (`CMS_TUNNEL_HELD_BY_HARNESS`) is true exactly when
  the harness runs this copy's connector, so the app skips its own; both sides
  derive it from the same fact. See knowledge/harness, "App instances".
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
  @callback stop_process(os_pid :: pos_integer()) :: :ok | {:error, term()}

  @doc """
  The `os_pid` of whatever is listening on `port` right now, or `nil` if
  nothing is. Main's port is fixed, so it can be held by a process this
  instance never launched.
  """
  @callback listener_pid(port :: pos_integer()) :: pos_integer() | nil

  @doc """
  The working directory of `os_pid`, or `nil` if it can't be read (the
  process is already gone, or this platform has no way to ask). Compared
  against a copy's `root` before anything is adopted or killed.
  """
  @callback process_root(os_pid :: pos_integer()) :: String.t() | nil

  @doc """
  Start a named Cloudflare tunnel for these credentials, pointed at
  `origin_url`. Not linked to the caller: `AppInstance` re-checks
  `Process.alive?/1` on later calls, so a dead tunnel reads as "not running".

  Keyed on the tunnel id: every caller handed the same tunnel gets the one
  running connector.
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

  @spec drop_database(String.t()) :: :ok | {:error, term()}
  def drop_database(database), do: impl().drop_database(database)

  @spec current_commit(String.t()) :: String.t() | nil
  def current_commit(root), do: impl().current_commit(root)

  @spec changed_paths(String.t(), String.t(), String.t()) :: [String.t()] | nil
  def changed_paths(root, from, to), do: impl().changed_paths(root, from, to)

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

  @spec stop_process(pos_integer()) :: :ok | {:error, term()}
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
