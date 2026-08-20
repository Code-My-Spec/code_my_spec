defmodule CodeMySpec.Release.PluginPortRewriteTest do
  @moduledoc """
  A shipped skill must still be able to reach a service.

  The source tree points at `:4004` so a dev harness can coexist with the
  packaged binary on `:4003`, and `PackageExtension.rewrite_ports/1` swaps them
  at release. That was a blanket token replace, which is correct for a single
  port and wrong for a *list* of them: every skill carries
  `PORTS="4004 4003"` and tries each in turn, and the blanket pass turned it
  into `"4003 4003"` — a fallback that falls back to itself.

  v2.0.2 shipped exactly that, and nothing failed. A packaging step that
  produces a plausible string has no other way to be wrong, which is why this
  asserts the property rather than the mechanism.

  Why a list at all: the two ports serve **disjoint** routes.
  `/api/harnesses/:id/skills/start` is 404 on `:4003` and 200 on `:4004`;
  `/api/skills/init` is the reverse. Neither port is right for everyone — a
  packaged-CLI user has `:4003` and no `:4004`, a dev checkout has the reverse
  — so a skill has to try both (`5fdc0cbf`, `6c93a317`).
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Release.PluginPorts

  @skills Path.expand("../../plugins/claude/skills", __DIR__)

  # Both spellings, because the repo has both — six `skill.md` and two
  # `SKILL.md`. macOS is case-insensitive so a single lowercase glob finds all
  # eight here and only six on Linux, where CI packages the release: the test
  # would pass while silently not checking `init` and `sync`.
  defp skill_files do
    # `uniq` because macOS matches both globs against the same file; on Linux
    # each matches its own.
    (Path.wildcard(Path.join(@skills, "*/skill.md")) ++
       Path.wildcard(Path.join(@skills, "*/SKILL.md")))
    |> Enum.uniq()
  end

  test "every skill file is found, whichever way it is spelled" do
    found = skill_files() |> Enum.map(&(&1 |> Path.dirname() |> Path.basename())) |> Enum.uniq()

    dirs =
      @skills
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(@skills, &1)))

    assert Enum.sort(found) == Enum.sort(dirs),
           "skills present but not checked: #{inspect(dirs -- found)} — a glob that " <>
             "misses a skill makes every assertion below vacuous for it"
  end

  defp port_list(content) do
    case Regex.run(~r/PORTS="([0-9 ]+)"/, content) do
      [_, list] -> String.split(list, " ", trim: true)
      nil -> nil
    end
  end

  # Only `init` still carries a pair.
  #
  # The other seven post to `/api/skills/start`, which the harness serves, so
  # one port is the whole answer and the rewrite is an ordinary single-token
  # swap. `init` posts to `/api/skills/init`, which only `CodeMySpecLocalWeb`
  # has — the two services expose disjoint routes, so init is the one client
  # that genuinely has to try both. That asymmetry is a known gap rather than a
  # design; if it closes, the pair handling in `PluginPorts` goes with it.
  defp with_port_list, do: Enum.filter(skill_files(), &port_list(File.read!(&1)))

  test "a skill whose route is on the other service still declares a pair" do
    assert with_port_list() != [], """
    No skill declares a port pair any more.

    Correct for the seven the harness serves. Wrong for `init`, whose route
    exists only on CodeMySpecLocalWeb — with one port it reaches whichever
    service the packager happened to aim it at, and 404s on the other.
    """
  end

  test "the shipped port list keeps two distinct ports, prod first" do
    for path <- with_port_list() do
      shipped = path |> File.read!() |> PluginPorts.rewrite() |> port_list()

      assert shipped == ["4003", "4004"], """
      #{Path.relative_to(path, @skills)} ships PORTS="#{Enum.join(shipped || [], " ")}".

      A shipped skill has to try the prod port first and still fall back to the
      dev one. Collapsing the pair is what v2.0.2 did, and the result reaches an
      agent as "Not Found" with nothing in any log — an unrouted path is refused
      by Plug before a controller exists to log it.
      """
    end
  end

  test "the dev tree keeps the dev port first" do
    for path <- with_port_list() do
      assert port_list(File.read!(path)) == ["4004", "4003"],
             "#{Path.relative_to(path, @skills)} does not try the dev harness first, so " <>
               "`just claude-dev` would reach the packaged binary instead of the checkout " <>
               "under test"
    end
  end

  test "an ordinary lone port is still rewritten" do
    # The behaviour the pair handling must not break: a single `4004` anywhere
    # else in the tree — plugin.json, bin/hook — still becomes the prod port.
    assert PluginPorts.rewrite(~s|"port": 4004|) == ~s|"port": 4003|
    assert PluginPorts.rewrite("${CODEMYSPEC_PORT:-4004}") == "${CODEMYSPEC_PORT:-4003}"
  end

  test "rewriting is idempotent on already-shipped content" do
    # The packager runs against a fresh copy, but a re-run must not walk the
    # pair back to a single port.
    once = PluginPorts.rewrite(~s|PORTS="4004 4003"|)

    assert PluginPorts.rewrite(once) == once,
           "a second pass collapsed the fallback, which makes the packaging step " <>
             "depend on how many times it has run"
  end
end
