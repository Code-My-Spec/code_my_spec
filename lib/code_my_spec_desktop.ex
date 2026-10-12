defmodule CodeMySpecDesktop do
  @moduledoc """
  The desktop build (bb8bc042): the server and the light harness in one
  release on a developer's machine, with the OS user as the only user.
  Started only by `CodeMySpecDesktop.Application`, the desktop env's `mod`.
  It sits above the web layer: what web asks of desktop mode (the desktop
  user, the OAuth handoff and clients) lives with its owners below.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Accounts,
      CodeMySpec.Integrations,
      CodeMySpec.Oauth,
      CodeMySpec.Paths,
      CodeMySpec.Release,
      CodeMySpec.Repo,
      CodeMySpec.UserPreferences,
      CodeMySpec.Users
    ],
    exports: :all
end
