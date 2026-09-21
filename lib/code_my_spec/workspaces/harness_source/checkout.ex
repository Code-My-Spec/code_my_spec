defmodule CodeMySpec.Workspaces.HarnessSource.Checkout do
  @moduledoc """
  This box's own `code_my_spec` checkout, run straight from source — so a
  fix lands in the next workspace it boots the moment it is promoted, rather
  than waiting on a separate, externally-published release this application
  does not control the cadence of. See `HarnessSource`'s own moduledoc for
  what trusting the installed release cost instead.

  `MIX_ENV=dev_sprite`, not `prod_cli`: `mix.exs` already says why —
  "dev_sprite ships the same release as prod_cli — a sprite is the CLI
  harness, just compiled against Postgres instead of SQLite" — and this
  server's own database is Postgres. `mix run --no-halt` rather than a
  packaged release for the same reason a release is skipped everywhere else
  in dev: assembling one costs minutes this workspace's visitor is waiting
  through, and `app_module/0` in `mix.exs` boots the identical
  `CodeMySpecLocalWeb.Application` either way — `mix run` is not a
  different harness, only a different way of starting the same one.

  `File.cwd!()`, not a configured path: the server evaluating this is
  already running from the main checkout — established practice on this
  project, not an assumption this module introduces — so asking the running
  process where it is answers correctly without a second place to keep that
  path in sync with reality.
  """

  @behaviour CodeMySpec.Workspaces.HarnessSource

  @impl true
  def command, do: "cd #{File.cwd!()} && MIX_ENV=dev_sprite mix run --no-halt"
end
