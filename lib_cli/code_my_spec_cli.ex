defmodule CodeMySpecCli do
  @moduledoc """
  CLI-only modules: daemon lifecycle, Burrito release steps, and the
  long-lived presence client that bridges the local agent to the
  remote server.

  Compiled only in `:dev_cli` and `:prod_cli`. Depends on
  `CodeMySpec.Auth.OAuthClient` for the cached token / server URL the
  presence socket needs; otherwise talks to the running server over
  HTTP.
  """

  use Boundary, top_level?: true, deps: [CodeMySpec], exports: :all
end
