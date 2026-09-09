defmodule CodeMySpec do
  @moduledoc """
  CodeMySpec keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.BootVersion,
      CodeMySpec.Code,
      CodeMySpec.CodeMode,
      CodeMySpec.Compile,
      CodeMySpec.Environments,
      CodeMySpec.Events,
      CodeMySpec.ExternalUsers,
      CodeMySpec.FileEdits,
      CodeMySpec.IndexNow,
      CodeMySpec.Mailer,
      CodeMySpec.Oauth,
      CodeMySpec.Paths,
      CodeMySpec.PublicUrl,
      CodeMySpec.Repo,
      CodeMySpec.Research,
      CodeMySpec.Rules,
      CodeMySpec.TempFile,
      CodeMySpec.Tests,
      CodeMySpec.Uploads,
      CodeMySpec.Vault
    ],
    exports: :all
end
