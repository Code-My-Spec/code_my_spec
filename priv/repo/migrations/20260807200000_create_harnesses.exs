defmodule CodeMySpec.Repo.Migrations.CreateHarnesses do
  use Ecto.Migration

  @moduledoc """
  A harness is a working copy the server knows about.

  Files and problems are projections of a working copy, but they have only ever
  been keyed by project — so two checkouts of one project write the same rows
  and each sync deletes what the other just wrote. This table is the grain that
  fixes it: the thing that owns a file is the checkout it was scanned from.

  Story 727 decided the identity is issued here rather than derived on the
  client. Every client-derived alternative fails a real case — two containers
  both at `/workspace/app` collide on path; a generated container hostname
  collides on host+path; a session id churns and would split a parent agent
  from its subagents. A local agent and a cloud agent on one branch, different
  machines and different uncommitted state, is the case that settles it.

  `label` is the harness's own description of itself — "the harness at <root>
  on <host>" — and exists so a refusal or an operator's picker can name *which
  checkout*, which an opaque id cannot. It is a display string, not identity:
  two checkouts may legitimately carry the same label and still be two
  harnesses.

  `last_seen_at` is what makes "show me the most recently active one" cheap.
  That is criterion 739's default, and it is a good default precisely because
  it needs no configuration and degrades correctly for a checkout nobody
  classified.

  Only the table here. `harness_id` on `files` and `problems` is the grain
  change itself and lands separately, with the backfill it needs.
  """

  def change do
    create table(:harnesses, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :text
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:harnesses, [:project_id])

    # Serving the operator's default view: the project's most recently active
    # harness, without reading every one of them.
    create index(:harnesses, [:project_id, :last_seen_at])
  end
end
