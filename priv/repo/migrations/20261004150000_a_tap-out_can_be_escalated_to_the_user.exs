defmodule CodeMySpec.Repo.Migrations.ATapOutCanBeEscalatedToTheUser do
  use Ecto.Migration

  # A permission request has no holder column — `OpenQuestion.from_permission/3`
  # computes it. Escalating one needs somewhere to keep the reason and the
  # person-facing framing, the same two things a question's escalation keeps,
  # so the computed holder has something to read once the main agent sends one
  # up rather than deciding it.
  def change do
    alter table(:permission_requests) do
      add :escalation_reason, :string
      add :escalated_as, :string
    end
  end
end
