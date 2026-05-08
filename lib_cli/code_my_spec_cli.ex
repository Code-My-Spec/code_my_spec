defmodule CodeMySpecCli do
  @moduledoc """
  CLI-only modules: daemon lifecycle + Burrito release steps.

  Compiled only in `:dev_cli` and `:prod_cli`. No deps on CodeMySpec
  internals — the daemon talks to the running server over HTTP, and
  the release steps are pure build-time helpers.
  """

  use Boundary, top_level?: true, exports: :all
end
