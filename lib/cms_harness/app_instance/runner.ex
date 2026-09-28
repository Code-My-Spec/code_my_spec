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
  `nil`. Main's app cannot be allocated a free port the way every other
  copy's is — it is the one address every bookmark, browser tab and the MCP
  endpoint already point at — so it has to be read off the same file that
  configures it, the same way `main_database_name/1` already does for the
  database.
  """
  @callback main_ports(root :: String.t()) :: {pos_integer(), pos_integer()} | nil

  @doc "Clone `main_database` into a fresh `database` — dump and restore, not a template."
  @callback clone_database(root :: String.t(), main_database :: String.t(), database :: String.t()) ::
              :ok | {:error, term()}

  @doc "Run `root`'s `seed` recipe, if it declares one. Always succeeds — seeding is optional."
  @callback seed(root :: String.t()) :: :ok

  @doc "Drop `database`. Never called on anything but this feature's own clone."
  @callback drop_database(database :: String.t()) :: :ok

  @doc "The commit `root`'s checkout is on, or `nil`."
  @callback current_commit(root :: String.t()) :: String.t() | nil

  @doc """
  Launch `root`'s `serve` recipe, detached, with `PORT`/`HTTPS_PORT`/
  `DATABASE_NAME` set and its output redirected to `log_path`.
  """
  @callback launch(
              root :: String.t(),
              port :: pos_integer(),
              https_port :: pos_integer(),
              database :: String.t(),
              log_path :: String.t()
            ) :: {:ok, os_pid :: pos_integer()} | {:error, term()}

  @doc "Whether `os_pid` can still be signalled."
  @callback alive?(os_pid :: pos_integer()) :: boolean()

  @doc "What the app on `port` is actually doing — same three states `Workspaces.Runner` uses."
  @callback probe(port :: pos_integer()) :: :serving | :erroring | :down

  @doc "Take the whole process tree rooted at `os_pid` down."
  @callback stop_process(os_pid :: pos_integer()) :: :ok

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

  @spec main_ports(String.t()) :: {pos_integer(), pos_integer()} | nil
  def main_ports(root), do: impl().main_ports(root)

  @spec clone_database(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def clone_database(root, main_database, database), do: impl().clone_database(root, main_database, database)

  @spec seed(String.t()) :: :ok
  def seed(root), do: impl().seed(root)

  @spec drop_database(String.t()) :: :ok
  def drop_database(database), do: impl().drop_database(database)

  @spec current_commit(String.t()) :: String.t() | nil
  def current_commit(root), do: impl().current_commit(root)

  @spec launch(String.t(), pos_integer(), pos_integer(), String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def launch(root, port, https_port, database, log_path),
    do: impl().launch(root, port, https_port, database, log_path)

  @spec alive?(pos_integer()) :: boolean()
  def alive?(os_pid), do: impl().alive?(os_pid)

  @spec probe(pos_integer()) :: :serving | :erroring | :down
  def probe(port), do: impl().probe(port)

  @spec stop_process(pos_integer()) :: :ok
  def stop_process(os_pid), do: impl().stop_process(os_pid)

  defp impl do
    :code_my_spec
    |> Application.get_env(CmsHarness.AppInstance, [])
    |> Keyword.get(:runner, CmsHarness.AppInstance.Runner.Local)
  end
end
