defmodule CodeMySpec.Repo.Migrations.AnEnvironmentCanPointAtALinkedServer do
  use Ecto.Migration

  @moduledoc """
  Let a project's environment reference an account-level server.

  `provisioning_environments` carries its own `server_name`/`ip`, filled in by
  the server step once it creates a box. That grain cannot express a box the
  account already owns and links across projects — story 879's own notes
  named this exact gap and deferred it. `server_id` is the re-grain: nullable,
  because most environments still get a dedicated box the server step
  creates, and this only matters for the ones pointed at something the
  account already had.

  `on_delete: :nilify_all` rather than restrict — unlinking or removing a
  server should not take a project's environment row down with it. What that
  environment is served by becomes unknown again, the same as before it was
  ever linked.
  """

  def change do
    alter table(:provisioning_environments) do
      add :server_id, references(:linked_servers, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:provisioning_environments, [:server_id])
  end
end
