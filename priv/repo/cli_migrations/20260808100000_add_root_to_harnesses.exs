defmodule CodeMySpec.Repo.Migrations.AddRootToHarnesses do
  use Ecto.Migration

  @moduledoc """
  The SQLite counterpart of the Postgres `add_root_to_harnesses`.

  Mirrored because the local server is the half that actually resolves hooks:
  it receives `X-Harness-Id` and has to answer "which directory is that?"
  without asking the cloud. A shared Ecto schema selecting a column SQLite
  lacks is how `SocketSupervisor` crashes on boot and takes MCP with it.
  """

  def change do
    alter table(:harnesses) do
      add :root, :text
    end
  end
end
