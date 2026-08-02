defmodule CodeMySpecWeb.LinkResolutionTest do
  @moduledoc """
  Every path a view links to must resolve to a real route.

  `~p` gives this for free, but only for `~p` — and only against the one router
  it was compiled with. The local app builds a lot of navigation as plain
  strings (`to: "/app/projects/\#{slug}/requirements"`), and those compile no
  matter what they point at. Moving the local routes under `/app` broke 278 of
  them at once; the pages still rendered, so a smoke pass that only asked
  "does this return 200" saw nothing wrong, and it surfaced as 331 spex
  failures three steps later.

  This walks the source for path literals and asks the router whether each one
  exists. It runs in under a second and fails on the specific dead link, which
  is the feedback loop a batch-by-batch UI migration needs.
  """
  use ExUnit.Case, async: true

  # Views and components only — routers and endpoints are where paths are
  # *declared*, and scanning them would just assert routes match themselves.
  @local_only ["lib/code_my_spec_local_web/live", "lib/code_my_spec_local_web/components"]
  @portable ["lib/code_my_spec_web/live/story_live"]

  # `/`-rooted strings in a view that aren't navigation. Keep this short and
  # justified — anything not listed here has to resolve, which is what makes
  # the check catch a link left pointing at a route that moved.
  defp not_a_link?(path) do
    # slash-commands shown to the user ("/codemyspec:next"), not URLs
    String.contains?(path, [":", " "]) or
      # static assets, served by Plug.Static rather than the router
      String.starts_with?(path, "/local/") or
      # section_path/1 renders a bare "/overview" into the terminal prompt strip
      path == "/overview"
  end

  defp path_literals(dirs) do
    dirs
    |> Enum.flat_map(&Path.wildcard(&1 <> "/**/*.{ex,heex}"))
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> then(&Regex.scan(~r/"(\/[a-z][^"\n]*)"/, &1))
      |> Enum.map(fn [_, path] -> {file, path} end)
    end)
    |> Enum.reject(fn {_file, path} -> not_a_link?(path) end)
    |> Enum.uniq()
  end

  # Segments of the literal. An interpolated segment becomes `:any` — it could
  # hold a slug, an id, or a literal like "knowledge", so it must be allowed to
  # match either a route's dynamic segment or its static one.
  defp link_segments(raw) do
    raw
    |> String.replace(~r/[?].*$/, "")
    |> String.replace(~r/\#\{[^}]*\}/, "\0")
    |> String.split("/", trim: true)
    |> Enum.map(fn
      seg -> if String.contains?(seg, "\0"), do: :any, else: seg
    end)
  end

  defp route_segments(router) do
    router.__routes__()
    |> Enum.map(&String.split(&1.path, "/", trim: true))
    |> Enum.uniq()
  end

  defp matches?(link, route) do
    cond do
      Enum.any?(route, &String.starts_with?(&1, "*")) ->
        prefix = Enum.take_while(route, &(not String.starts_with?(&1, "*")))
        length(link) >= length(prefix) and
          Enum.zip(prefix, Enum.take(link, length(prefix))) |> Enum.all?(&seg_match?/1)

      length(link) != length(route) ->
        false

      true ->
        Enum.zip(route, link) |> Enum.all?(&seg_match?/1)
    end
  end

  defp seg_match?({_route_seg, :any}), do: true
  defp seg_match?({":" <> _, _link_seg}), do: true
  defp seg_match?({route_seg, link_seg}), do: route_seg == link_seg

  defp unresolvable(dirs, routers) do
    for {file, raw} <- path_literals(dirs),
        link = link_segments(raw),
        router <- routers,
        not Enum.any?(route_segments(router), &matches?(link, &1)),
        do: "#{Path.relative_to_cwd(file)}: #{raw}  →  no route in #{inspect(router)}"
  end

  test "local app links resolve against the local router" do
    dead = unresolvable(@local_only, [CodeMySpecLocalWeb.Router])

    assert dead == [], """
    Dead links in the local app — these compile fine and 404 at runtime:

    #{Enum.join(dead, "\n")}
    """
  end

  test "portable view links resolve against BOTH routers" do
    dead = unresolvable(@portable, [CodeMySpecWeb.Router, CodeMySpecLocalWeb.Router])

    assert dead == [], """
    A portable view links somewhere one of its two hosts can't serve. Shared
    views are mounted by both routers, so every link has to exist in both:

    #{Enum.join(dead, "\n")}
    """
  end
end
