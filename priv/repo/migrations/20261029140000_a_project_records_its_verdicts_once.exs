defmodule CodeMySpec.Repo.Migrations.AProjectRecordsItsVerdictsOnce do
  @moduledoc """
  Verdicts that read only the project's records, stored once per project.

  `requirements` held every verdict once per checkout, but only file-backed
  verdicts and the three that read project issues (which leave out issues on
  stories placed elsewhere) differ between checkouts. The rest (story issues, stories,
  QA, deploys, documents, and personas, which read every checkout's files) move
  here, keyed
  by owner and name like `requirements` without a checkout. Per-checkout copies
  drifted: rows written by an older checker that read the checkout stayed
  behind on the checkouts no drain reached.

  The per-checkout rows are deleted here, not reaped by the writer: a checkout
  holding names its templates no longer define per checkout would reseed. They
  are regenerable; each projector writes this table on its first drain.
  """

  use Ecto.Migration

  @names ~w(
    component_linked three_amigos_complete questions_answered story_issues_triaged
    ready_for_qa qa_complete story_promoted deploy dependencies_met submitted
    qa_setup qa_journey_plan stories_exist personas_complete
  )

  def up do
    create table(:project_requirements) do
      add :name, :string, null: false
      add :description, :text, null: false
      add :satisfied, :boolean, null: false
      add :details, :map, null: false
      add :checked_at, :naive_datetime_usec
      add :inputs_fingerprint, :string
      add :owner_component_type, :string
      add :node_scope, :string
      add :component_id, references(:components, type: :binary_id, on_delete: :delete_all)
      add :story_id, references(:stories, on_delete: :delete_all)
      add :issue_id, references(:issues, type: :binary_id, on_delete: :delete_all)
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:project_requirements, [:component_id, :name],
             where: "component_id IS NOT NULL"
           )

    create unique_index(:project_requirements, [:story_id, :name], where: "story_id IS NOT NULL")
    create unique_index(:project_requirements, [:issue_id, :name], where: "issue_id IS NOT NULL")

    create unique_index(:project_requirements, [:project_id, :name],
             where: "project_id IS NOT NULL"
           )

    execute("DELETE FROM requirements WHERE name IN (#{Enum.map_join(@names, ", ", &"'#{&1}'")})")
  end

  def down do
    drop table(:project_requirements)
  end
end
