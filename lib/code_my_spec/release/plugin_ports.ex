defmodule CodeMySpec.Release.PluginPorts do
  @moduledoc """
  The dev → prod port rewrite applied to the plugin tree at release.

  The source tree points at `:4004` so a dev harness can coexist with the
  packaged binary on `:4003`. Packaging swaps them.

  ## Why a list, and why it is reordered rather than replaced

  The two ports serve **disjoint** routes:

      /api/harnesses/:id/skills/start   :4003 404   :4004 200
      /api/skills/init                  :4003 400   :4004 404

  Neither is right for everyone — a packaged-CLI user has `:4003` and no
  `:4004`, a dev checkout has the reverse — so every skill carries
  `PORTS="4004 4003"` and tries each in turn.

  A blanket token swap is correct for a lone port and wrong for that pair: it
  produces `"4003 4003"`, a fallback that falls back to itself. v2.0.2 shipped
  exactly that, and nothing failed, because a packaging step that emits a
  *plausible* string has no other way to be wrong. What an agent saw was "Not
  Found" with nothing in any log — an unrouted path is refused by Plug before a
  controller exists to log it — and three sessions were spent concluding "stale
  plugin" (`6c93a317`, `5fdc0cbf`, `36ecc1ff`).

  So the pair is lifted out, the blanket pass runs, and the pair goes back with
  the prod port leading.

  ## Why this lives in `lib` rather than beside the packager

  `lib_cli` is not in the test environment's `elixirc_paths`, so nothing under
  it can be tested by `mix test` — which is why this transform had no tests and
  could ship broken. The rule is a product decision about what a released
  plugin must be able to reach; the packager is one caller of it.
  """

  @dev_first "4004 4003"
  @prod_first "4003 4004"
  @sentinel "__CMS_PORT_FALLBACK__"

  @doc """
  Rewrite one file's contents from the dev port to the prod port.

  A lone `4004` becomes `4003`. The fallback pair `4004 4003` becomes
  `4003 4004` — reordered, so a shipped skill tries prod first and can still
  reach a dev harness.

  Idempotent: running it twice does not collapse the pair.
  """
  @spec rewrite(String.t()) :: String.t()
  def rewrite(content) do
    content
    |> String.replace(@dev_first, @sentinel)
    # The already-shipped pair is lifted out too, so a second pass is a no-op
    # rather than a collapse. The packager runs once against a fresh copy today,
    # which is exactly the kind of assumption that stops holding quietly.
    |> String.replace(@prod_first, @sentinel)
    |> String.replace("4004", "4003")
    |> String.replace(@sentinel, @prod_first)
  end

  @doc "The port list a source-tree skill declares."
  @spec dev_first() :: String.t()
  def dev_first, do: @dev_first

  @doc "The port list a shipped skill must declare."
  @spec prod_first() :: String.t()
  def prod_first, do: @prod_first
end
