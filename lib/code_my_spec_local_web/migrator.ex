defmodule CodeMySpecLocalWeb.Migrator do
  @moduledoc """
  Runs Ecto migrations on application startup, synchronously.

  Sits in the supervision tree between Repo and the children that
  query the schema at init (Endpoint, SocketSupervisor, BootSync).
  `start_link/1` blocks the supervisor until migrations complete and
  returns `:ignore` so no process is supervised — this is one-shot
  setup, not a long-lived worker.

  The previous `Task.start_link` shape returned immediately, leaving
  downstream children racing the migrator on a fresh DB.
  """

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :temporary
    }
  end

  def start_link(_opts) do
    run()
    :ignore
  end

  # A sprite must not migrate. Its database is shared and central: it is
  # migrated once by the server's deploy, not by each client that connects.
  # Letting sprites migrate would mean N of them racing the same DDL on
  # startup, and would require granting the sprite role DDL rights it should
  # never hold — the role is meant to be DML-only, which is a large part of
  # why one shared database is safe to start with.
  #
  # It is also simply the wrong migration set: the CLI's SQLite migrations
  # rebuild a schema the server's migrations already created, so the first
  # one fails with `relation "projects" already exists`.
  def run do
    if Application.get_env(:code_my_spec, :env) == :dev_sprite do
      :ok
    else
      migrate_local()
    end
  end

  defp migrate_local do
    migrations_path = Application.app_dir(:code_my_spec, "priv/repo/cli_migrations")

    if File.exists?(migrations_path) do
      Ecto.Migrator.run(CodeMySpec.Repo, migrations_path, :up, all: true)
    end
  end
end
