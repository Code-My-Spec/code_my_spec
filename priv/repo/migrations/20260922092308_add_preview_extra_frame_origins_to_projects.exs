defmodule CodeMySpec.Repo.Migrations.AddPreviewExtraFrameOriginsToProjects do
  use Ecto.Migration

  # A previewed app's own OAuth redirects need `frame-src` origins beyond the
  # preview's own — see `CodeMySpec.Workspaces.PreviewAddress`. Per project
  # rather than global, so one customer's extra provider does not widen the
  # policy for everyone else's preview.
  #
  # No default here, matching `setup_options` next to it: a default in the
  # migration and a default on the schema drift, and the schema's is the one
  # the application reads. `nil` means "never customized", which
  # `PreviewAddress.extra_frame_origins/1` turns into the built-in
  # accounts.google.com/github.com pair.
  def change do
    alter table(:projects) do
      add :preview_extra_frame_origins, {:array, :string}
    end
  end
end
