defmodule CodeMySpecDesktop do
  @moduledoc """
  The desktop build (bb8bc042): the server and the light harness in one
  release on a developer's machine, with the OS user as the only user.
  Compiled everywhere because the web layer asks `Identity` for a scope;
  started only by `CodeMySpecDesktop.Application`, the desktop env's `mod`.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CodeMySpec.Accounts,
      CodeMySpec.Oauth,
      CodeMySpec.Release,
      CodeMySpec.Repo,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users
    ],
    exports: :all
end
