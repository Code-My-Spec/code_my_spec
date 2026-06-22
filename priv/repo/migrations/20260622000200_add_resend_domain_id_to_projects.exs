defmodule CodeMySpec.Repo.Migrations.AddResendDomainIdToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :resend_domain_id, :string
    end
  end
end
