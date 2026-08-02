defmodule CodeMySpec.Repo.Migrations.CreateProvisioningEnvironments do
  use Ecto.Migration

  # An environment is a named remote server with connection metadata. That is
  # the whole concept — `prod` and `uat` are two rows, not two ideas, and
  # nothing here knows their names. A project can have a `qa` environment, or
  # one per story, without a code change.
  #
  # Before this, `["prod", "uat"]` was a literal repeated in seven places in
  # `Provisioning.Steps`. Every step that fanned out over environments fanned
  # out over that literal, so "add an environment" meant editing seven call
  # sites, and the server and DNS steps — the two that actually make the thing
  # an environment *is* — never fanned out at all: one server, one set of
  # records, for all of them.
  #
  # `host` is stored rather than derived so no step has to special-case a name.
  # Production's host is the apex (`example.com`), UAT's is `uat.example.com`,
  # and a per-story QA environment's is whatever it was created with. The DNS
  # step just points each environment's host at its own IP.
  def change do
    create table(:provisioning_environments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false

      # The public hostname this environment answers on. Null until the domain
      # is known — an environment can exist before it has anywhere to live.
      add :host, :string

      # Connection metadata, filled in by the server step once the box exists.
      # Null means "not provisioned yet", which is a real state and not an
      # error: the environment is the plan, the server is the fulfilment.
      add :server_name, :string
      add :ip, :string

      timestamps(type: :utc_datetime)
    end

    # Names are per project, and they become server names, DNS labels and SOPS
    # key filenames — so one project cannot hold two environments called `uat`.
    create unique_index(:provisioning_environments, [:project_id, :name])
  end
end
