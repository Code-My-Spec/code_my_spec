defmodule CodeMySpec.Repo.Migrations.AddIssueRequirementOwners do
  use Ecto.Migration

  def change do
    for target <- [:requirements, :shadow_requirements] do
      alter table(target) do
        add(:issue_id, references(:issues, type: :binary_id, on_delete: :delete_all))
      end

      create(
        unique_index(target, [:issue_id, :name, :working_copy_id],
          where: "issue_id IS NOT NULL",
          nulls_distinct: false
        )
      )
    end
  end
end
