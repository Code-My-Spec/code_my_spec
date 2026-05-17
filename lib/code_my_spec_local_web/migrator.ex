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

  def run do
    migrations_path = Application.app_dir(:code_my_spec, "priv/repo/cli_migrations")

    if File.exists?(migrations_path) do
      Ecto.Migrator.run(CodeMySpec.Repo, migrations_path, :up, all: true)
    end
  end
end
