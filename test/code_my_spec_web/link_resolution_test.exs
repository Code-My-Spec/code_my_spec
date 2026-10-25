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

  # Assigns the project hook puts on the socket; a component must declare any
  # it uses.
  @host_assigns ~w(project current_scope projects)

  # Derived, not listed: a project view is one mounted inside the router's
  # `:project` live_session. Hardcoding directories would rot on the first
  # surface added, and a guard that silently stops covering things is worse
  # than no guard.
  defp project_sources do
    CodeMySpecWeb.Router.__routes__()
    |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug and project?(&1)))
    |> MapSet.new(&elem(&1.metadata.phoenix_live_view, 0))
    |> Enum.map(&(&1.__info__(:compile)[:source] |> to_string() |> Path.relative_to_cwd()))
    |> Enum.filter(&File.exists?/1)
    |> Enum.uniq()
  end

  defp project?(route) do
    {_live_view, _action, _opts, live_session} = route.metadata.phoenix_live_view
    live_session.name == :project
  end

  # `/`-rooted strings in a view that aren't navigation. Keep this short and
  # justified — anything not listed here has to resolve, which is what makes
  # the check catch a link left pointing at a route that moved.
  defp not_a_link?(path) do
    # slash-commands shown to the user ("/codemyspec:next"), not URLs
    # static assets, served by Plug.Static rather than the router
    # section_path/1 renders a bare "/overview" into the terminal prompt strip
    # Controller-served attachment bytes, not navigation
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

  test "project view links resolve against the router" do
    sources = project_sources()

    assert sources != [],
           "no project views found — the :project live_session should include at least the stories surface"

    dead = unresolvable(sources, [CodeMySpecWeb.Router])

    assert dead == [], """
    A project view links somewhere the router can't serve:

    #{Enum.join(dead, "\n")}
    """
  end

  test "no function component in a project view reaches for an undeclared hook assign" do
    # A helper called as `render_index(assigns)` receives the whole assigns map
    # and sees everything. A component invoked as `<.thing attr={..}>` gets only
    # what it declares, so a host assign used there raises KeyError the first
    # time it renders — clean compile, failure only once it's on screen.
    offenders = Enum.flat_map(project_sources(), &offenders_in/1)

    assert offenders == [], """
    A function component in a project view uses a hook-provided assign it never
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
      |> Enum.filter(
        &(&1.plug == Phoenix.LiveView.Plug and &1.path =~ ~r{^/app/projects/:project_id/})
      )
      |> Enum.map(&elem(&1.metadata.phoenix_live_view, 0))
      |> Enum.uniq()
      |> Enum.map(&(&1.__info__(:compile)[:source] |> to_string() |> Path.relative_to_cwd()))
      |> Enum.filter(&(File.exists?(&1) and missing_project_assign?(&1)))

    assert missing == [], """
    A project-scoped view renders <Layouts.app> without passing project=, so
    its sidebar falls back to the project picker and the page becomes a dead
    end:

    #{Enum.map_join(missing, "\n", &("  " <> &1))}

    Pass project={assigns[:project]} and projects={assigns[:projects] || []}.
    """
  end

  defp missing_project_assign?(file) do
    src = File.read!(file)
    String.contains?(src, "<Layouts.app") and not String.contains?(src, "project={")
  end

  # Surfaces with no sidebar entry, and why. The first is by design; the rest
  # are findings this guard surfaced on its first run — mounted in both routers
  # and linked from nowhere in either app. They are listed to keep the guard
  # green on a known set rather than to justify them; a surface leaving this
  # list means it either got a nav entry or got deleted.
  @intentionally_unlinked [
    # Onboarding entry point — reached from Home and from init, not from the
    # nav of a project that is by definition not yet set up.
    "/app/projects/:project_id/init",
    # TaskQueueLive. Nothing links it in either app.
    "/app/projects/:project_id/tasks",
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
    "/app/projects/:project_id/architecture/namespaces",
    # The console's own sections: reached from its own sidebar once you're
    # on `/console`, same as the tabs above — only the surface itself,
    # `/console`, belongs in the cloud app's nav.
    "/app/projects/:project_id/console/resources",
    "/app/projects/:project_id/console/servers",
    "/app/projects/:project_id/console/inventory",
    "/app/projects/:project_id/console/dev-boxes",
    "/app/projects/:project_id/console/devices",
    "/app/projects/:project_id/console/deploys",
    "/app/projects/:project_id/console/secrets",
    "/app/projects/:project_id/console/credentials",
    "/app/projects/:project_id/console/activity",
    # The Operations console's sections, reached from its sidebar; the nav's
    # Operations entry opens Chats (`/inbox`).
    "/app/projects/:project_id/content",
    "/app/projects/:project_id/users",
    "/app/projects/:project_id/mailboxes",
    "/app/projects/:project_id/mail"
  ]

  @doc false
  # A migrated surface that nothing links to is invisible. Twelve of the
  # thirteen views moved into CodeMySpecWeb were mounted in the cloud router
  # and reachable only by typing the URL — the migration looked complete from
  # every angle except opening the app. Route parity says both apps *serve*
  # the surface; this says the cloud app will actually take you there.
  test "every project surface is reachable from its sidebar" do
    sidebar = File.read!("lib/code_my_spec_web/components/layouts.ex")

    served =
      CodeMySpecWeb.Router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> Enum.map(& &1.path)
      # Every project route whose tail is entirely static — not just the
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
