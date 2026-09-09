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
      CodeMySpec.Analytics,
      CodeMySpec.BootVersion,
      CodeMySpec.Code,
      CodeMySpec.CodeMode,
      CodeMySpec.Compile,
      CodeMySpec.Encrypted.Binary,
      CodeMySpec.Environments,
      CodeMySpec.Events,
      CodeMySpec.ExternalUsers,
      CodeMySpec.FileEdits,
      CodeMySpec.IndexNow,
      CodeMySpec.Mailer,
      CodeMySpec.Oauth,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.PublicUrl,
      CodeMySpec.Release,
      CodeMySpec.Repo,
      CodeMySpec.Research,
      CodeMySpec.Rules,
      CodeMySpec.TempFile,
      CodeMySpec.Tests,
      CodeMySpec.Uploads,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.Vault
    ],
    exports: :all
end
