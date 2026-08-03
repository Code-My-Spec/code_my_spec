defmodule CodeMySpec.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  # A workspace is one project's running instance. The row exists so the
  # visitor's screen can survive a reconnect and still know whether their app
  # came up — booting takes long enough that "we lost track of it" is a real
  # failure mode, and the story treats being left on a spinner as a defect.
  #
  # `status` carries `failed` as a first-class value rather than inferring it
  # from a missing container, because the difference the visitor cares about is
  # "still coming up" versus "it broke", and only one of those is worth waiting
  # through.
  def change do
    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :status, :string, null: false

      # How the runner addresses the instance. Null until the runner has
      # accepted it — a workspace row can exist before anything is running.
      add :container_name, :string
      add :port, :integer

      # What went wrong, in terms the visitor can be shown.
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    # One instance per project. A second boot adopts the existing row rather
    # than racing a duplicate container onto another port.
    create unique_index(:workspaces, [:project_id])
  end
end
