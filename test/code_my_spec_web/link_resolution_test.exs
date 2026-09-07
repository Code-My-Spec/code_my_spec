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
    # static assets, served by Plug.Static rather than the router
    # section_path/1 renders a bare "/overview" into the terminal prompt strip
    # Controller-served attachment bytes, not navigation. These live only in
    # the cloud router because serving them needs an account scope the local
    # app doesn't have yet; the portable view that links to one hides it
    # behind the host's `serves_attachments?` capability. Delete this clause
    # when the local app gets a cloud scope and can mount the controllers.
    String.contains?(path, [":", " "]) or
      String.starts_with?(path, "/local/") or
      path == "/overview" or
      String.ends_with?(path, "/screenshot")
  end

  defp path_literals(paths) do
    paths
    |> Enum.flat_map(&expand(File.dir?(&1), &1))
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> then(&Regex.scan(~r/"(\/[a-z][^"\n]*)"/, &1))
      |> Enum.map(fn [_, path] -> {file, path} end)
    end)
    |> Enum.reject(fn {_file, path} -> not_a_link?(path) end)
    |> Enum.uniq()
  end

  defp expand(true, dir), do: Path.wildcard(dir <> "/**/*.{ex,heex}")
  defp expand(false, file), do: [file]

  # Segments of the literal. An interpolated segment becomes `:any` — it could
  # hold a slug, an id, or a literal like "knowledge", so it must be allowed to
  # match either a route's dynamic segment or its static one.
  defp link_segments(raw) do
    raw
    |> String.replace(~r/[?].*$/, "")
    |> String.replace(~r/\#\{[^}]*\}/, "\0")
    |> String.split("/", trim: true)
    |> Enum.map(&segment(String.contains?(&1, "\0"), &1))
  end

  defp segment(true, _interpolated), do: :any
  defp segment(false, literal), do: literal

  defp route_segments(router) do
    router.__routes__()
    |> Enum.map(&String.split(&1.path, "/", trim: true))
    |> Enum.uniq()
  end

  defp matches?(link, route),
    do: matches?(Enum.any?(route, &String.starts_with?(&1, "*")), link, route)

  # A glob route matches any link that agrees on the segments before the glob.
  defp matches?(true, link, route) do
    prefix = Enum.take_while(route, &(not String.starts_with?(&1, "*")))

    length(link) >= length(prefix) and
      prefix |> Enum.zip(Enum.take(link, length(prefix))) |> Enum.all?(&seg_match?/1)
  end

  defp matches?(false, link, route) when length(link) != length(route), do: false
  defp matches?(false, link, route), do: route |> Enum.zip(link) |> Enum.all?(&seg_match?/1)

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

    assert sources != [],
           "no portable views found — both routers should share at least the stories surface"

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
    |> Enum.reduce({nil, MapSet.new(), MapSet.new(), []}, &scan_line(&1, &2, file, src))
    |> elem(3)
  end

  # Classify the line once, then dispatch on the shape. `attr` declarations
  # precede the definition they belong to, so they accumulate into `pending`
  # and become `declared` when the next component definition is reached.
  defp scan_line({line, n}, state, file, src) do
    attr = Regex.run(~r/^\s*attr :([a-z_]+)/, line)
    defn = Regex.run(~r/^  defp? ([a-z_]+)\(assigns\)/, line)
    comment? = String.starts_with?(String.trim(line), "#")

    absorb({attr, defn, comment?}, state, line, n, file, src)
  end

  defp absorb({[_, name], _defn, _comment?}, {fun, declared, pending, acc}, _l, _n, _f, _s),
    do: {fun, declared, MapSet.put(pending, name), acc}

  defp absorb({nil, [_, name], _comment?}, {_fun, _declared, pending, acc}, _l, _n, _f, _s),
    do: {name, pending, MapSet.new(), acc}

  defp absorb({nil, nil, true}, state, _line, _n, _file, _src), do: state

  defp absorb({nil, nil, false}, {fun, declared, pending, acc}, line, n, file, src),
    do: {fun, declared, pending, flag(file, n, line, fun, declared, src) ++ acc}

  defp flag(file, n, line, fun, declared, src) do
    fun
    |> component?(src)
    |> host_assigns_in(line, declared)
    |> report(file, n, line)
  end

  # Only a function component can reach for an assign it wasn't given; a plain
  # helper called as `foo(assigns)` receives the whole map.
  defp component?(nil, _src), do: false
  defp component?(fun, src), do: String.contains?(src, "<." <> fun)

  defp host_assigns_in(false, _line, _declared), do: []

  defp host_assigns_in(true, line, declared) do
    ~r/@([a-z_]+)/
    |> Regex.scan(line)
    |> Enum.map(&Enum.at(&1, 1))
    |> Enum.filter(&(&1 in @host_assigns and not MapSet.member?(declared, &1)))
    |> Enum.uniq()
  end

  defp report([], _file, _n, _line), do: []

  defp report(used, file, n, line),
    do: [{file, n, "uses @" <> Enum.join(used, ", @") <> " — " <> String.trim(line)}]

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

  # A project-scoped page that wraps itself in `<Layouts.app>` has to hand the
  # layout the project, because a function component only receives what it
  # declares. Reach for `@project` without passing it and the sidebar renders
  # its other branch — the project picker — so the page loads, looks fine, and
  # is the only place in the app you cannot navigate out of. The previous test
  # says the nav entry exists; this says the nav is still there once you use
  # it. WorkingCopiesLive shipped with the entry and without the assign.
  test "every project-scoped view that wraps itself passes the project to the layout" do
    missing =
      CodeMySpecWeb.Router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> Enum.filter(&(&1.path =~ ~r{^/app/projects/:project_id/}))
      |> Enum.map(&elem(&1.metadata.phoenix_live_view, 0))
      |> Enum.uniq()
      |> Enum.map(&(&1.__info__(:compile)[:source] |> to_string() |> Path.relative_to_cwd()))
      |> Enum.filter(&File.exists?/1)
      |> Enum.filter(fn file ->
        src = File.read!(file)
        String.contains?(src, "<Layouts.app") and not String.contains?(src, "project={")
      end)

    assert missing == [], """
    A project-scoped view renders <Layouts.app> without passing project=, so
    its sidebar falls back to the project picker and the page becomes a dead
    end:

    #{Enum.map_join(missing, "\n", &("  " <> &1))}

    Pass project={assigns[:project]} and projects={assigns[:projects] || []}.
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
    # ProjectSetupLive. Brownfield onboarding, entered deliberately from Home
    # and from init — a generated project exits `cms new` with setup already
    # complete, so a permanent nav entry would offer every project a checklist
    # that only some of them need. Setup stopped being a graph requirement in
    # 545fb741 for the same reason.
    "/app/projects/:project_id/setup",
    # TaskQueueLive. Nothing links it in either app.
    "/app/projects/:project_id/tasks",
    # ProvisioningLive. Arrived on main with no nav entry and no inbound link.
    "/app/projects/:project_id/provisioning",
    # The credentials, environments and secrets dialogs, each opened from the
    # provisioning page through `:live_action` (058d20ed, and the same pattern
    # extended to the other two). A dialog reached from the page it belongs to
    # is exactly the case this list is for; a sidebar entry that opens a modal
    # over a page you were not on is not a surface anyone wants offered.
    "/app/projects/:project_id/provisioning/credentials",
    "/app/projects/:project_id/provisioning/environments",
    "/app/projects/:project_id/provisioning/secrets",
    # Reached from their own list page's actions, not from the sidebar — a nav
    # entry that opens a blank form is a worse offer than the button on the
    # page you are already looking at.
    "/app/projects/:project_id/stories/new",
    "/app/projects/:project_id/stories/import",
    "/app/projects/:project_id/epics/new",
    "/app/projects/:project_id/personas/new",
    # Tabs and alternate views within a surface that IS in the nav. Listing
    # each one separately would make the sidebar a sitemap.
    "/app/projects/:project_id/stories/scheduler",
    "/app/projects/:project_id/requirements/stories",
    "/app/projects/:project_id/architecture/overview",
    "/app/projects/:project_id/architecture/namespaces",
    "/app/projects/:project_id/components/graph"
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
      # Every portable route whose tail is entirely static — not just the
      # single-segment ones. `/requirements/graph` sat unlinked in the cloud
      # sidebar for exactly as long as this only matched one segment, and the
      # guard reported green the whole time. Routes with a dynamic tail
      # (`:slug`, `:id`, `*path`) are detail pages reached from a list, not
      # destinations a sidebar offers.
      |> Enum.filter(&(&1 =~ ~r{^/app/projects/:project_id/[a-z0-9/-]+$}))
      |> Enum.uniq()

    unlinked =
      served
      |> Enum.reject(fn path ->
        segment = path |> String.split("/") |> List.last()
        path in @intentionally_unlinked or sidebar =~ ~s{/#{segment}"}
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
