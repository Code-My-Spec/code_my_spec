defmodule CodeMySpecLocalWeb.Migrator do
  @moduledoc """
  Runs Ecto migrations on application startup.

  Added as a child after Repo so migrations run unconditionally,
  regardless of whether CliRunner starts (e.g., daemon/server mode).
  """
  use Task, restart: :temporary

  def start_link(_opts) do
    Task.start_link(__MODULE__, :run, [])
  end

  def run do
    migrations_path = Application.app_dir(:code_my_spec, "priv/repo/migrations/cli")

    if File.exists?(migrations_path) do
      Ecto.Migrator.run(CodeMySpec.Repo, migrations_path, :up, all: true)
    end
  end
end
