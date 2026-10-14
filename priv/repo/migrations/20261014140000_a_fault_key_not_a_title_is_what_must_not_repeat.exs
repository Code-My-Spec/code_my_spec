defmodule CodeMySpec.Repo.Migrations.AFaultKeyNotATitleIsWhatMustNotRepeat do
  use Ecto.Migration

  @moduledoc """
  20261014120000 and 20261014130000 keyed the storyless-duplicate guard on
  `title` directly. `title` is free text any caller chooses, and two
  unrelated issues from two unrelated callers can share one by coincidence
  (test/spex/1016_.../criterion_1749, both scope `:app`; the real collision
  was test/spex/1026_.../criterion_2060, same scope `:framework` as a fault
  issue, same hardcoded title, different purpose entirely). A constraint
  keyed on free text can never tell "the same fault, filed twice" apart from
  "two different issues that happen to use the same words."

  `fault_key` is new, nullable, and set only by `Agents.Main.file_fault/5` --
  nothing else in the system ever writes it, so nothing else can collide
  with it. The old title-keyed index is dropped.
  """

  def change do
    drop(index(:issues, [:title, :project_id], name: :issues_title_project_id_no_story_index))

    alter table(:issues) do
      add :fault_key, :string
    end

    create(
      unique_index(:issues, [:fault_key, :project_id],
        name: :issues_fault_key_project_id_index,
        where: "fault_key IS NOT NULL AND status <> 'resolved'"
      )
    )
  end
end
