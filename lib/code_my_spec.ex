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
      CodeMySpec.Accounts,
      CodeMySpec.Analytics,
      CodeMySpec.AppTokens,
      CodeMySpec.Auth,
      CodeMySpec.Authorization,
      CodeMySpec.Billing,
      CodeMySpec.BootVersion,
      CodeMySpec.ClientUsers.ClientUser,
      CodeMySpec.CmsUsers,
      CodeMySpec.Code,
      CodeMySpec.CodeMode,
      CodeMySpec.Compile,
      CodeMySpec.Content,
      CodeMySpec.ContentPublishing,
      CodeMySpec.Dependencies,
      CodeMySpec.Embeddings,
      CodeMySpec.Encrypted.Binary,
      CodeMySpec.Environments,
      CodeMySpec.Events,
      CodeMySpec.ExternalUsers,
      CodeMySpec.FileEdits,
      CodeMySpec.Git,
      CodeMySpec.GitHub,
      CodeMySpec.Google,
      CodeMySpec.Host,
      CodeMySpec.IndexNow,
      CodeMySpec.Integrations,
      CodeMySpec.Invitations,
      CodeMySpec.Knowledge,
      CodeMySpec.Logging,
      CodeMySpec.Mail,
      CodeMySpec.Mailer,
      CodeMySpec.Oauth,
      CodeMySpec.Paths,
      CodeMySpec.Projects,
      CodeMySpec.ProjectSecrets,
      CodeMySpec.ProjectUsers,
      CodeMySpec.PublicUrl,
      CodeMySpec.Release,
      CodeMySpec.Repo,
      CodeMySpec.Research,
      CodeMySpec.Rules,
      CodeMySpec.ScreenState,
      CodeMySpec.TaskHelp,
      CodeMySpec.TempFile,
      CodeMySpec.Tests,
      CodeMySpec.Transcripts,
      CodeMySpec.Uploads,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users,
      CodeMySpec.Utils,
      CodeMySpec.Vault
    ],
    exports: :all
end
