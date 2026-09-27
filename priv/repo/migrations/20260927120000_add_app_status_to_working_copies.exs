defmodule CodeMySpec.Repo.Migrations.AddAppStatusToWorkingCopies do
  use Ecto.Migration

  # Story 1108: every working copy runs its own instance of the app, not just
  # the main checkout's preview. `preview_status`/`preview_url` already exist
  # on this table but are the main-only public tunnel address — reusing them
  # here would conflate "is the public preview tunnel answering" with "is
  # this copy's own local dev instance answering," which are different
  # copies asking different questions on the same sync.
  #
  # `app_commit` is separate from `Project.head_commit` because that field is
  # one value per project, clobbered by whichever copy last synced — it
  # cannot represent copy A serving one commit while copy B serves another,
  # which is exactly the state two working copies running side by side need
  # to distinguish.
  def change do
    alter table(:working_copies) do
      add :app_status, :string
      add :app_checked_at, :utc_datetime_usec
      add :app_url, :string
      add :app_commit, :string
    end
  end
end
