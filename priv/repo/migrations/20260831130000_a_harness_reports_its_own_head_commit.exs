defmodule CodeMySpec.Repo.Migrations.AHarnessReportsItsOwnHeadCommit do
  @moduledoc """
  `Steps.image_tag/2` tags a build with the project's `git rev-parse HEAD` —
  unreadable server-side for a harness-only project the same way `mix.exs`
  and `envs/<env>.enc.env` are. The harness runs `git` locally, where the
  checkout really is, and reports the SHA here on every sync.
  """

  use Ecto.Migration

  def change do
    alter table(:projects) do
      add :head_commit, :string
    end
  end
end
