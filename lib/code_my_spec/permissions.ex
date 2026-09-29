defmodule CodeMySpec.Permissions do
  @moduledoc """
  Boundary for `PermissionSocket`, the client the local permission controllers
  use to wait on a human's decision over the production server's socket.

  Tap-out is not here: it is a `PermissionRequest` row, written and resolved by
  `Notifications` (e96115a9).
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Auth,
      CodeMySpec.Repo,
      CodeMySpec.Sessions,
      CodeMySpec.Users,
      CodeMySpec.Users.Scope
    ],
    exports: :all
end
