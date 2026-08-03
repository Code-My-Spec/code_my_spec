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

  # Assigns the host puts on the socket; a component must declare any it uses.
  @host_assigns ~w(slug project scope socket scope_error projects)

  # Views and components only — routers and endpoints are where paths are
  # *declared*, and scanning them would just assert routes match themselves.
  @local_only ["lib/code_my_spec_local_web/live", "lib/code_my_spec_local_web/components"]

  # Derived, not listed: a view is portable exactly when both routers mount it.
  # Hardcoding the directories would rot on the first surface migrated, and a
  # guard that silently stops covering things is worse than no guard.
  defp portable_sources do
    views = fn router ->
      router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> MapSet.new(&elem(&1.metadata.phoenix_live_view, 0))
    end

    MapSet.intersection(views.(CodeMySpecWeb.Router), views.(CodeMySpecLocalWeb.Router))
    |> Enum.map(&(&1.__info__(:compile)[:source] |> to_string() |> Path.relative_to_cwd()))
    |> Enum.filter(&File.exists?/1)
    |> Enum.uniq()
  end

  # `/`-rooted strings in a view that aren't navigation. Keep this short and
  # justified — anything not listed here has to resolve, which is what makes
  # the check catch a link left pointing at a route that moved.
  defp not_a_link?(path) do
    # slash-commands shown to the user ("/codemyspec:next"), not URLs
    String.contains?(path, [":", " "]) or
      # static assets, served by Plug.Static rather than the router
      String.starts_with?(path, "/local/") or
      # section_path/1 renders a bare "/overview" into the terminal prompt strip
      path == "/overview" or
      # Controller-served attachment bytes, not navigation. These live only in
      # the cloud router because serving them needs an account scope the local
      # app doesn't have yet; the portable view that links to one hides it
      # behind the host's `serves_attachments?` capability. Delete this clause
      # when the local app gets a cloud scope and can mount the controllers.
      String.ends_with?(path, "/screenshot")
  end

  defp path_literals(paths) do
    paths
    |> Enum.flat_map(fn p ->
      if File.dir?(p), do: Path.wildcard(p <> "/**/*.{ex,heex}"), else: [p]
    end)
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
    sources = portable_sources()

    assert sources != [], "no portable views found — both routers should share at least the stories surface"

    dead = unresolvable(sources, [CodeMySpecWeb.Router, CodeMySpecLocalWeb.Router])

    assert dead == [], """
    A portable view links somewhere one of its two hosts can't serve. Shared
    views are mounted by both routers, so every link has to exist in both:

    #{Enum.join(dead, "\n")}
    """
  end

  test "no function component in a portable view reaches for a host assign" do
    # A helper called as `render_index(assigns)` receives the whole assigns map
    # and sees everything. A component invoked as `<.thing attr={..}>` gets only
    # what it declares, so a host assign used there raises KeyError the first
    # time it renders — clean compile, failure only once it's on screen.
    offenders = Enum.flat_map(portable_sources(), &offenders_in/1)

    assert offenders == [], """
    A function component in a portable view uses a host-provided assign it never
    declared. Pass it down as a declared attr.

    #{Enum.map_join(offenders, "\n", fn {f, n, l} -> "  #{Path.relative_to_cwd(f)}:#{n}  #{l}" end)}
    """
  end

  defp offenders_in(file) do
    src = File.read!(file)

    src
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({nil, MapSet.new(), MapSet.new(), []}, fn {line, n},
                                                            {fun, declared, pending, acc} ->
      attr = Regex.run(~r/^\s*attr :([a-z_]+)/, line)
      defn = Regex.run(~r/^  defp? ([a-z_]+)\(assigns\)/, line)

      cond do
        # `attr` declarations precede the definition they belong to
        attr -> {fun, declared, MapSet.put(pending, Enum.at(attr, 1)), acc}
        defn -> {Enum.at(defn, 1), pending, MapSet.new(), acc}
        String.starts_with?(String.trim(line), "#") -> {fun, declared, pending, acc}
        true -> {fun, declared, pending, flag(file, n, line, fun, declared, src) ++ acc}
      end
    end)
    |> elem(3)
  end

  defp flag(file, n, line, fun, declared, src) do
    used =
      if fun && String.contains?(src, "<." <> fun) do
        Regex.scan(~r/@([a-z_]+)/, line)
        |> Enum.map(&Enum.at(&1, 1))
        |> Enum.filter(&(&1 in @host_assigns))
        |> Enum.reject(&MapSet.member?(declared, &1))
        |> Enum.uniq()
      else
        []
      end

    if used == [],
      do: [],
      else: [{file, n, "uses @" <> Enum.join(used, ", @") <> " — " <> String.trim(line)}]
  end

  test "every portable view assigns the layout's required assigns" do
    # The router-level layout reads :page_title and :section from the socket.
    # Before the migration each view passed them as literal attrs on its own
    # `<Layouts.app page_title="...">`, so dropping the wrapper silently left
    # them unassigned — a KeyError on first render, which took down nine spex
    # once and eighty another time before this check existed.
    missing =
      for file <- portable_sources(),
          src = File.read!(file),
          key <- ["page_title", "section"],
          # matches both `page_title: "x"` and `assign(:page_title, "x")`
          not Regex.match?(~r/:?\b#{key}\b\s*[,:]/, src),
          do: "#{Path.relative_to_cwd(file)} never assigns :#{key}"

    assert missing == [], """
    A portable view doesn't assign something the layout reads:

    #{Enum.join(missing, "\n")}
    """
  end

  # Surfaces with no sidebar entry, and why. The first is by design; the rest
  # are findings this guard surfaced on its first run — mounted in both routers
  # and linked from nowhere in either app. They are listed to keep the guard
  # green on a known set rather than to justify them; a surface leaving this
  # list means it either got a nav entry or got deleted.
  @intentionally_unlinked [
    # Onboarding entry point — reached from Home and from the setup flow, not
    # from the nav of a project that is by definition not yet set up.
    "/app/projects/:project_id/init",
    # TaskQueueLive. Nothing links it in either app.
    "/app/projects/:project_id/tasks",
    # AgentProgressLive — story 813, parked before it was wired into nav.
    "/app/projects/:project_id/progress",
    # ProvisioningLive. Arrived on main with no nav entry and no inbound link.
    "/app/projects/:project_id/provisioning",
    # AgentConversationLive — a read-only view of one sprite's turns. It only
    # became visible to this guard when its route moved from :project_name to
    # :project_id and started matching the portable shape. Nothing links it.
    "/app/projects/:project_id/agent-conversation"
  ]

  @doc false
  # A migrated surface that nothing links to is invisible. Twelve of the
  # thirteen views moved into CodeMySpecWeb were mounted in the cloud router
  # and reachable only by typing the URL — the migration looked complete from
  # every angle except opening the app. Route parity says both apps *serve*
  # the surface; this says the cloud app will actually take you there.
  test "every portable surface the cloud serves is reachable from its sidebar" do
    sidebar = File.read!("lib/code_my_spec_web/components/layouts.ex")

    served =
      CodeMySpecWeb.Router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> Enum.map(& &1.path)
      |> Enum.filter(&(&1 =~ ~r{^/app/projects/:project_id/[a-z-]+$}))
      |> Enum.uniq()

    unlinked =
      served
      |> Enum.reject(&(&1 in @intentionally_unlinked))
      |> Enum.reject(fn path ->
        segment = path |> String.split("/") |> List.last()
        sidebar =~ ~s{/#{segment}"}
      end)

    assert unlinked == [], """
    Mounted in the cloud router but absent from the cloud sidebar, so the only
    way to reach them is to type the URL:

    #{Enum.map_join(unlinked, "\n", &("  " <> &1))}

    Add a nav entry in lib/code_my_spec_web/components/layouts.ex, or if the
    surface is deliberately unlisted (reached from inside another page), name
    it in @intentionally_unlinked with the page that links to it.
    """
  end

end
