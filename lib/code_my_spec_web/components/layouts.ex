defmodule CodeMySpecWeb.Layouts do
  @moduledoc """
  Page layouts (`app`, `marketing`, `live`) and shared chrome — flash group,
  theme toggle.
  """
  use CodeMySpecWeb, :html

  import CodeMySpecWeb.AccountLive.Components.AccountsBreadcrumb
  import CodeMySpecWeb.ProjectLive.Components.ProjectBreadcrumb

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Layout entry point for `live_session ..., layout: {__MODULE__, :live}`.

  The cloud half of the same contract `CodeMySpecLocalWeb.Layouts.live/1`
  implements: portable LiveViews render content only, and the router decides
  which chrome wraps it.
  """
  attr :inner_content, :any, required: true

  def live(assigns) do
    ~H"""
    <.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      {@inner_content}
    </.app>
    """
  end

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_path, :string, default: "/"

  # The sidebar's two halves. `project` is the one named in the path, put there
  # by PortableHost — nil on any page that names none, which is what makes the
  # nav switch to the picker. `projects` is what the picker offers.
  #
  # Declared, not read off `assigns`: a function component only receives what
  # it declares, so reaching for an undeclared assign here silently renders the
  # empty branch on every page. Which is exactly what it did.
  attr :project, :map, default: nil, doc: "project named in the current path, if any"
  attr :projects, :list, default: [], doc: "projects this user can open (CurrentPathHook)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%!-- `h-dvh`, not `min-h-dvh`: a *minimum* is a floor a tall page can stand
    on and then exceed, which is exactly what let one oversized analyzer result
    grow the whole document instead of scrolling inside its own pane. `h-dvh`
    is a cap — `dvh` over `vh` for the same reason as before, so the cap itself
    tracks the keyboard rather than sitting fixed to the largest viewport. --%>
    <div class="app-zone drawer lg:drawer-open h-dvh">
      <input id="drawer-toggle" type="checkbox" class="drawer-toggle" />

      <%!-- daisyUI's `.drawer` is `display: grid`, and its own `.drawer-content`
      rule resets `min-width` but never `min-height` — so a grid item here
      still defaults to `min-height: auto` and refuses to shrink below its
      content, the grid version of the flex `min-h-0` bug already fixed
      further down this chain. Without this, the cap above does nothing: the
      grid cell blows out past it before `overflow-y-auto` ever gets a
      bounded box to scroll inside.

      `overflow-y-auto` lands here rather than lower because most pages under
      this layout have no scroll region of their own — a plain stories or
      requirements list just grows past one screen and expects the page to
      scroll. This is where that scroll now happens, in the one grid cell
      `h-dvh` bounds, instead of on `<html>`. A page that *does* own its
      viewport — this conversation, the chat surfaces — fills all of `main`
      with its own `min-h-0`/`overflow-y-auto` region, so this outer one never
      has anything left to scroll and stays inert underneath it. --%>
      <div class="drawer-content flex min-h-0 flex-col overflow-y-auto bg-base-100">
        <div class="navbar bg-base-200 border-b border-base-300">
          <div class="flex-none lg:hidden">
            <label for="drawer-toggle" class="btn btn-square btn-ghost">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                fill="none"
                viewBox="0 0 24 24"
                class="inline-block w-5 h-5 stroke-current"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 6h16M4 12h16M4 18h16"
                >
                </path>
              </svg>
            </label>
          </div>
          <div class="flex-1 min-w-0">
            <%!--
              `:if={@current_scope}` is a nil guard, not a return of the
              onboarding gate that used to sit here. Both breadcrumbs declare
              `attr :scope, :map, required: true` and dereference
              `scope.active_account_id`, so a page reached without a scope
              crashes the layout rather than rendering without them.

              The gate that was removed happened to cover this, because
              `onboarding_complete?/1` answered false for a nil scope. Taking it
              out was right — the guided intake onboards without the ladder — but
              it took the nil safety with it, and /invitations/accept is reached
              by someone who has no account yet, which is the whole point of an
              invitation.
            --%>
            <div :if={@current_scope} class="breadcrumbs text-sm px-2 lg:px-8 overflow-hidden">
              <ul>
                <li><.account_breadcrumb scope={@current_scope} current_path={@current_path} /></li>
                <li><.project_breadcrumb scope={@current_scope} current_path={@current_path} /></li>
              </ul>
            </div>
          </div>
          <div class="flex-none shrink-0">
            <.live_component
              :if={@current_scope}
              module={CodeMySpecWeb.NotificationLive.Components.Dropdown}
              id="notification-dropdown"
              current_scope={@current_scope}
            />
            <button
              id="enable-notifications-btn"
              phx-click={JS.dispatch("phx:toggle-push-notifications")}
              class="btn btn-ghost btn-sm tooltip tooltip-left"
              data-tip="Enable notifications"
              data-subscribed="false"
            >
              <span data-notif-icon-off><.icon name="hero-bell" class="size-5" /></span>
              <span data-notif-icon-on class="hidden">
                <.icon name="hero-bell-alert-solid" class="size-5 text-primary" />
              </span>
            </button>
          </div>
        </div>

        <%!-- `min-h-0` and a column, so a page that wants to own the viewport
        can. Without it a full-height child grows the document instead of
        scrolling inside itself, the whole page scrolls, and a chat's
        composer-at-the-bottom ends up below the fold.

        `p-4` on a phone: 24px of padding each side costs a eighth of a 390px
        screen before anything is drawn. --%>
        <main class="flex min-h-0 flex-1 flex-col p-4 lg:p-6">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side">
        <label for="drawer-toggle" class="drawer-overlay"></label>
        <aside class="w-64 min-h-full bg-base-200">
          <div class="p-6 border-b border-base-300">
            <%!-- Home is the cockpit once there is a project to open — the
            screen work happens on, not the overview that describes getting
            started. `/app` remains home for someone who has not got one yet,
            which is exactly the onboarding it still renders. --%>
            <a href={home_path(@project)} class="flex items-center gap-3">
              <img src={~p"/images/logo.svg"} alt="CodeMySpec" class="h-6 w-6" />
              <span class="text-lg font-semibold">CodeMySpec</span>
            </a>
          </div>
          <ul class="menu p-4 w-64 min-h-full text-base-content">
            <li><a href={~p"/app"}>Overview</a></li>
            <li><a href={~p"/app/projects"}>Projects</a></li>
            <%!--
                Account-scoped, so it sits with Projects rather than inside the
                per-project block: a box is shared between projects, and one
                left over from a project that no longer exists still bills.
              --%>
            <li><a href={~p"/app/servers"}>Servers</a></li>
            <li><a href={~p"/app/devices"}>Devices</a></li>
            <li><a href={~p"/app/resources"}>Resources</a></li>
            <%!--
                The path is the breadcrumb. Every surface below is addressed
                per-project, and the project they point at is the one named in
                the URL — `@project`, put there by PortableHost — never the
                stored preference. A stored one could contradict the page you
                are looking at; the preference now only decides where bare
                `/app` sends you, which is a different question.

                With no project in the path there is nothing to build links
                from, so the sidebar offers the choice instead of going blank.

                Persisted, not merely present: `/app/projects/new` assigns a
                blank `%Project{}` as its form's subject under the same name,
                and a struct with a nil id satisfied the old check and then
                raised building the first link — so the page that creates a
                project was the one page you could not open.
              --%>
            <%= if (project = @project) && project.id do %>
              <li class="menu-title truncate" title={project.name}>{project.name}</li>
              <li class="menu-title">Specification</li>
              <li><a href={~p"/app/projects/#{project.id}/stories"}>Stories</a></li>
              <li><a href={~p"/app/projects/#{project.id}/epics"}>Epics</a></li>
              <li><a href={~p"/app/projects/#{project.id}/personas"}>Personas</a></li>
              <li><a href={~p"/app/projects/#{project.id}/requirements"}>Requirements</a></li>
              <li><a href={~p"/app/projects/#{project.id}/requirements/graph"}>Graph</a></li>
              <li><a href={~p"/app/projects/#{project.id}/architecture"}>Architecture</a></li>
              <li><a href={~p"/app/projects/#{project.id}/components"}>Components</a></li>

              <li class="menu-title">Build</li>
              <%!-- Brownfield onboarding. Listed rather than hidden because it
                    is the only way in for an existing project, and a route
                    nobody can navigate to is a route nobody uses. A project
                    generated by `cms new` opens it to twelve of twelve done,
                    which the page says. --%>
              <li><a href={~p"/app/projects/#{project.id}/setup"}>Setup</a></li>
              <li><a href={~p"/app/projects/#{project.id}/provisioning"}>Provisioning</a></li>
              <li><a href={~p"/app/projects/#{project.id}/next-task"}>Next task</a></li>
              <li><a href={~p"/app/projects/#{project.id}/files"}>Files &amp; sync</a></li>
              <li><a href={~p"/app/projects/#{project.id}/problems"}>Problems</a></li>
              <li><a href={~p"/app/projects/#{project.id}/qa"}>QA</a></li>
              <li><a href={~p"/app/projects/#{project.id}/sessions"}>Sessions</a></li>
              <li><a href={~p"/app/projects/#{project.id}/working-copies"}>Working copies</a></li>
              <li><a href={~p"/app/projects/#{project.id}/agent-conversation"}>Agent chat</a></li>
              <%!-- "Agent chat" opens whichever session the cockpit defaults to.
                    This is the list of all of them — the way to reach the four a
                    project with five agents would otherwise hide. --%>
              <li>
                <a href={~p"/app/projects/#{project.id}/agent-conversations"}>Agent sessions</a>
              </li>
              <li><a href={~p"/app/projects/#{project.id}/issues"}>Issues</a></li>

              <li class="menu-title">Project</li>
              <li><a href={~p"/app/projects/#{project.id}/content"}>Content</a></li>
              <li><a href={~p"/app/projects/#{project.id}/knowledge"}>Knowledge base</a></li>
              <li>
                <a href={~p"/app/projects/#{project.id}/project-knowledge"}>Project knowledge</a>
              </li>
              <li><a href={~p"/app/projects/#{project.id}/configuration"}>Configuration</a></li>
              <li><a href={~p"/app/projects/#{project.id}/users"}>Users</a></li>
              <li><a href={~p"/app/projects/#{project.id}/inbox"}>Chats</a></li>
              <li><a href={~p"/app/projects/#{project.id}/mail"}>Mail</a></li>
              <li :if={can_manage_mailboxes?(@current_scope)}>
                <a href={~p"/app/projects/#{project.id}/mailboxes"}>Mailboxes</a>
              </li>
            <% else %>
              <li class="menu-title">Open a project</li>
              <li :for={p <- @projects}>
                <a href={~p"/app/projects/#{p.id}/stories"} class="truncate" title={p.name}>
                  {p.name}
                </a>
              </li>
              <li :if={@projects == []} class="px-4 py-2 text-sm opacity-60">
                No projects yet.
              </li>
            <% end %>
            <li class="mt-auto"><a href={~p"/app/accounts"}>Accounts</a></li>
            <li><a href={~p"/app/users/settings"}>Settings</a></li>
            <%= if @current_scope do %>
              <li class="border-t border-base-300 mt-2 pt-2">
                <div class="text-xs opacity-60 px-2 truncate" title={@current_scope.user.email}>
                  {@current_scope.user.email}
                </div>
              </li>
              <li>
                <.link href={~p"/users/log-out"} method="delete">
                  <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
                </.link>
              </li>
            <% end %>
          </ul>
        </aside>
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # Marks the nav item for the section you are actually in.
  #
  # Prefix match, not equality: a blog post lives at /blog/:slug and is still
  # the Blog section. Guarded on the boundary so /blogroll does not light up
  # /blog, which is the bug a bare String.starts_with?/2 would have.
  # Where the logo goes. Same rule as "Open workspace" below, off the project in
  # the current path rather than off the scope, because the logo sits on a page
  # that already knows which project you are looking at.
  # Guarded on the id being a real one: the project form renders this layout
  # around a project that does not exist yet, and `~p` raises rather than
  # rendering a broken link when handed `nil`.
  defp home_path(%{id: id}) when is_binary(id), do: ~p"/app/projects/#{id}/agent-conversation"
  defp home_path(_no_project), do: ~p"/app"

  # Where "Open workspace" goes.
  #
  # `/app` for a visitor with nothing selected, and straight to the project for
  # someone who has one — the point of the button is resuming work, and landing
  # on the Overview to click through to the project you already chose is the
  # ceremony story 813 exists to remove, one step later than it used to be.
  #
  # Reads `active_project_id` rather than `active_project`, so it does not
  # depend on the preference having preloaded the struct. `Scope.for_user/1`
  # populates both from user preferences, so a dead marketing view has it.
  #
  # The cockpit rather than the project's detail page: John, on what people
  # should be working from, "this is what people should be working from
  # entirely". Resuming work means the screen with the agent and the panels on
  # it, not the page describing the project.
  defp workspace_path(%{active_project_id: id}) when is_binary(id),
    do: ~p"/app/projects/#{id}/agent-conversation"

  defp workspace_path(_scope), do: ~p"/app"

  defp nav_active(nil, _section), do: nil

  defp nav_active(current_path, section) do
    if current_path == section or String.starts_with?(current_path, section <> "/"),
      do: "menu-active font-semibold",
      else: nil
  end

  # Only owners/admins administer mailboxes, so the Mailboxes nav item is
  # theirs alone. Guarded on an active account so it never raises for a
  # half-onboarded scope.
  defp can_manage_mailboxes?(%{active_account_id: account_id} = scope) when is_binary(account_id),
    do: CodeMySpec.Mail.can_administer?(scope)

  defp can_manage_mailboxes?(_), do: false

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders the marketing/public layout for home page and blog.

  This layout provides a clean, marketing-focused design without app navigation.

  ## Examples

      <Layouts.marketing current_path={assigns[:current_path]} flash={@flash}>
        <h1>Content</h1>
      </Layouts.marketing>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :page_title, :string, default: "CodeMySpec"

  slot :inner_block, required: true

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  # Dead views get this from Plugs.CurrentPath, LiveViews from CurrentPathHook.
  # Defaults to nil rather than "/" so a caller that passes nothing highlights
  # nothing, instead of quietly claiming the visitor is on the home page.
  attr :current_path, :string, default: nil

  def marketing(assigns) do
    assigns = assign(assigns, :workspace_path, workspace_path(assigns[:current_scope]))

    ~H"""
    <div class="drawer">
      <input id="marketing-drawer-toggle" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content min-h-screen flex flex-col">
        <!-- Navbar — hamburger toggles the drawer on <lg; on lg+ the nav renders
             inline, with the feature pages nested under Product as a hover
             dropdown whose trigger still navigates. -->
        <header class="border-b border-base-300">
          <nav class="navbar max-w-7xl mx-auto px-4">
            <div class="navbar-start">
              <label
                for="marketing-drawer-toggle"
                class="btn btn-square btn-ghost lg:hidden"
                aria-label="Open menu"
              >
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  fill="none"
                  viewBox="0 0 24 24"
                  class="inline-block w-5 h-5 stroke-current"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M4 6h16M4 12h16M4 18h16"
                  />
                </svg>
              </label>
              <a href={~p"/"} class="btn btn-ghost text-xl normal-case px-2">
                <img
                  src={~p"/images/logo.svg"}
                  alt="CodeMySpec"
                  class="h-8 w-8"
                  width="32"
                  height="32"
                />
                <span class="hidden sm:inline">CodeMySpec</span>
              </a>
            </div>
            <div class="navbar-center hidden lg:flex">
              <%!-- Product is a hover dropdown whose trigger still navigates:
                   clicking goes to /product, hovering reveals the feature pages
                   nested under it. `dropdown-hover` also opens on :focus-within,
                   so keyboard users get it too, and the mobile drawer below
                   lists everything flat for touch.

                   New feature pages go in this list, not the top level. --%>
              <ul class="menu menu-horizontal menu-md px-1">
                <li class="dropdown dropdown-hover dropdown-bottom">
                  <.link href={~p"/product"} class="gap-1.5">
                    Product <span class="hero-chevron-down-micro size-3 opacity-60"></span>
                  </.link>
                  <%!-- w-max sizes the panel to its longest item so nothing wraps;
                       whitespace-nowrap keeps it that way as items are added. --%>
                  <ul class="dropdown-content menu menu-sm bg-base-100 border border-base-300 rounded-box z-[1] w-max p-2 shadow-lg mt-1">
                    <li><.link href={~p"/product"} class="whitespace-nowrap">Overview</.link></li>
                    <li>
                      <.link href={~p"/design-system"} class="whitespace-nowrap">Design system</.link>
                    </li>
                    <li>
                      <.link href={~p"/behavior"} class="whitespace-nowrap">Behavior</.link>
                    </li>
                    <li>
                      <.link href={~p"/agents"} class="whitespace-nowrap">Supported agents</.link>
                    </li>
                    <li>
                      <.link href={~p"/vibe-coding-rebuild"} class="whitespace-nowrap">
                        Rebuild service
                      </.link>
                    </li>
                    <li><.link href={~p"/install"} class="whitespace-nowrap">Install</.link></li>
                  </ul>
                </li>
                <li>
                  <.link href={~p"/developers"} class={nav_active(@current_path, "/developers")}>
                    Developers
                  </.link>
                </li>
                <li>
                  <.link href={~p"/methodology"} class={nav_active(@current_path, "/methodology")}>
                    Method
                  </.link>
                </li>
                <li>
                  <.link href={~p"/pricing"} class={nav_active(@current_path, "/pricing")}>
                    Pricing
                  </.link>
                </li>
                <li>
                  <.link href={~p"/blog"} class={nav_active(@current_path, "/blog")}>
                    Blog
                  </.link>
                </li>
                <li>
                  <.link href={~p"/documentation"} class={nav_active(@current_path, "/documentation")}>
                    Docs
                  </.link>
                </li>
              </ul>
            </div>
            <div class="navbar-end gap-1 sm:gap-2">
              <div class="hidden sm:block mr-1"><.theme_toggle /></div>
              <%= if @current_scope do %>
                <span class="hidden">{@current_scope.user.email}</span>
                <.link
                  href={~p"/users/log-out"}
                  method="delete"
                  class="btn btn-ghost hidden sm:inline-flex"
                >
                  Log out
                </.link>
                <.link href={@workspace_path} class="btn btn-primary">Open workspace</.link>
              <% else %>
                <.link href={~p"/users/log-in"} class="btn btn-ghost hidden sm:inline-flex">
                  Log in
                </.link>
                <.link href={~p"/install"} class="btn btn-primary">Start free</.link>
              <% end %>
            </div>
          </nav>
        </header>

        <main class="flex-1">
          {render_slot(@inner_block)}
        </main>

        <footer class="border-t border-base-300">
          <div class="max-w-7xl mx-auto px-6 py-10">
            <div class="grid grid-cols-2 md:grid-cols-4 gap-8 mb-8">
              <div>
                <h4 class="font-bold text-sm mb-3 text-base-content">Product</h4>
                <ul class="space-y-2 text-sm text-base-content/70">
                  <li>
                    <a href="/product" class="hover:text-primary transition-colors">Overview</a>
                  </li>
                  <li>
                    <a href="/developers" class="hover:text-primary transition-colors">
                      For developers
                    </a>
                  </li>
                  <li>
                    <a href="/agents" class="hover:text-primary transition-colors">
                      Supported agents
                    </a>
                  </li>
                  <li>
                    <a href="/design-system" class="hover:text-primary transition-colors">
                      Design system
                    </a>
                  </li>
                  <li>
                    <a href="/behavior" class="hover:text-primary transition-colors">
                      Behavior
                    </a>
                  </li>
                  <li>
                    <a href="/vibe-coding-rebuild" class="hover:text-primary transition-colors">
                      Rebuild service
                    </a>
                  </li>
                  <li>
                    <a href="/install" class="hover:text-primary transition-colors">Install</a>
                  </li>
                  <li>
                    <a href="/methodology" class="hover:text-primary transition-colors">
                      Methodology
                    </a>
                  </li>
                  <li><a href="/pricing" class="hover:text-primary transition-colors">Pricing</a></li>
                  <li>
                    <a href="/case-studies" class="hover:text-primary transition-colors">
                      Case Studies
                    </a>
                  </li>
                  <li>
                    <a href="/users/register" class="hover:text-primary transition-colors">
                      Get Started
                    </a>
                  </li>
                </ul>
              </div>
              <div>
                <h4 class="font-bold text-sm mb-3 text-base-content">Content</h4>
                <ul class="space-y-2 text-sm text-base-content/70">
                  <li><a href="/blog" class="hover:text-primary transition-colors">Blog</a></li>
                  <li>
                    <a href="/documentation" class="hover:text-primary transition-colors">
                      Documentation
                    </a>
                  </li>
                  <li><a href="/pages" class="hover:text-primary transition-colors">Pages</a></li>
                  <li>
                    <a href="/pages/founder-story" class="hover:text-primary transition-colors">
                      Founder Story
                    </a>
                  </li>
                  <li>
                    <a href="/pages/about" class="hover:text-primary transition-colors">About</a>
                  </li>
                </ul>
              </div>
              <div>
                <h4 class="font-bold text-sm mb-3 text-base-content">Legal</h4>
                <ul class="space-y-2 text-sm text-base-content/70">
                  <li>
                    <a href="/pages/privacy-policy" class="hover:text-primary transition-colors">
                      Privacy Policy
                    </a>
                  </li>
                  <li>
                    <a href="/pages/terms-of-service" class="hover:text-primary transition-colors">
                      Terms of Service
                    </a>
                  </li>
                  <li>
                    <a
                      href="/pages/end-user-license-agreement"
                      class="hover:text-primary transition-colors"
                    >
                      EULA
                    </a>
                  </li>
                </ul>
              </div>
              <div>
                <h4 class="font-bold text-sm mb-3 text-base-content">Connect</h4>
                <ul class="space-y-2 text-sm text-base-content/70">
                  <li>
                    <a
                      href="https://github.com/code-my-spec"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="hover:text-primary transition-colors"
                    >
                      GitHub
                    </a>
                  </li>
                  <li>
                    <a
                      href="https://www.linkedin.com/in/john-davenport-software/"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="hover:text-primary transition-colors"
                    >
                      LinkedIn
                    </a>
                  </li>
                  <li>
                    <a
                      href="https://x.com/johns10d"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="hover:text-primary transition-colors"
                    >
                      X / Twitter
                    </a>
                  </li>
                  <li>
                    <a
                      href="https://www.youtube.com/@codemyspec"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="hover:text-primary transition-colors"
                    >
                      YouTube
                    </a>
                  </li>
                </ul>
              </div>
            </div>
            <div class="border-t border-base-300 pt-6 flex flex-col sm:flex-row justify-between items-center gap-2 text-sm text-base-content/50">
              <div>© {Date.utc_today().year} CodeMySpec</div>
              <div>One person. A whole software company.</div>
            </div>
          </div>
        </footer>

        <.flash_group flash={@flash} />
      </div>

      <div class="drawer-side z-20">
        <label for="marketing-drawer-toggle" aria-label="close menu" class="drawer-overlay"></label>
        <aside class="w-72 min-h-full bg-base-200 flex flex-col">
          <div class="p-6 border-b border-base-300">
            <a href={~p"/"} class="flex items-center gap-3">
              <img src={~p"/images/logo.svg"} alt="CodeMySpec" class="h-6 w-6" />
              <span class="text-lg font-semibold">CodeMySpec</span>
            </a>
          </div>
          <ul class="menu p-4 text-base-content flex-1">
            <li><.link href={~p"/product"}>Product</.link></li>
            <li>
              <.link href={~p"/developers"} class={nav_active(@current_path, "/developers")}>
                Developers
              </.link>
            </li>
            <li><.link href={~p"/agents"}>Supported agents</.link></li>
            <li><.link href={~p"/design-system"}>Design system</.link></li>
            <li><.link href={~p"/vibe-coding-rebuild"}>Rebuild service</.link></li>
            <li>
              <.link href={~p"/methodology"} class={nav_active(@current_path, "/methodology")}>
                Method
              </.link>
            </li>
            <li>
              <.link href={~p"/pricing"} class={nav_active(@current_path, "/pricing")}>
                Pricing
              </.link>
            </li>
            <li>
              <.link href={~p"/blog"} class={nav_active(@current_path, "/blog")}>
                Blog
              </.link>
            </li>
            <li>
              <.link href={~p"/documentation"} class={nav_active(@current_path, "/documentation")}>
                Docs
              </.link>
            </li>
          </ul>
          <div class="p-4 border-t border-base-300 flex flex-col gap-2">
            <%= if @current_scope do %>
              <div class="text-xs opacity-60 px-1 truncate" title={@current_scope.user.email}>
                {@current_scope.user.email}
              </div>
              <.link href={@workspace_path} class="btn btn-primary btn-block">Open workspace</.link>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-block">
                Log out
              </.link>
            <% else %>
              <.link href={~p"/users/log-in"} class="btn btn-ghost btn-block">Log in</.link>
              <.link href={~p"/install"} class="btn btn-primary btn-block">Start free</.link>
            <% end %>
          </div>
        </aside>
      </div>
    </div>
    """
  end

  @doc """
  End-of-post install signature.

  Ships on every published blog post, so it reads as the author's signature
  rather than a per-post pitch.

  ## Why it is this quiet

  The audience is senior Phoenix engineers and technical founders, who read an
  aggressive end-of-post CTA as marketing smell — and once they do, the post
  loses credibility retroactively. So: author voice, one CTA, commands as
  copy-pasteable terminal text rather than buttons, and honesty about the
  signup gate instead of promising a frictionless install.

  The absence of urgency framing is enforced, not merely intended — the
  contract test refutes "GET STARTED", "Limited time", "Join thousands",
  "10x", and any exclamation mark anywhere in the rendered output.

  Both links carry the same UTM triple so blog→register conversion is
  attributable separately from the nav, homepage and Reddit-comment paths,
  which is the whole reason this block exists.
  """
  def install_signature(assigns) do
    ~H"""
    <aside class="not-prose mt-12 card border border-base-300 bg-base-200/40">
      <div class="card-body gap-4">
        <p class="text-base-content/80">
          I built this with
          <a
            href="/case-studies/market-my-spec?utm_source=blog&utm_medium=signature&utm_campaign=post-cta"
            class="link"
          >
            CodeMySpec
          </a>
          — the harness I work in.
        </p>

        <p class="text-base-content/80">Sign up (free, no card) then install:</p>

        <div class="mockup-code text-sm">
          <p data-prefix="$">
            <code>/plugin marketplace add Code-My-Spec/plugins</code>
          </p>
          <p data-prefix="$">
            <code>/plugin install codemyspec@codemyspec</code>
          </p>
        </div>

        <div>
          <%!--
            A plain anchor, not <.link>. The component renders href through
            dynamic attribute escaping, which turns & into &amp; — and the
            UTM triple has to survive verbatim for the analytics split this
            block exists for. A literal href in HEEx is left as authored.
          --%>
          <a
            href="/users/register?utm_source=blog&utm_medium=signature&utm_campaign=post-cta"
            data-event-label="cta-signature-register"
            class="btn btn-primary"
          >
            Create your free account
          </a>
        </div>

        <p class="text-base-content/70">— John</p>
      </div>
    </aside>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "system"})}
        class="flex p-2 cursor-pointer w-1/3"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "light"})}
        class="flex p-2 cursor-pointer w-1/3"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "dark"})}
        class="flex p-2 cursor-pointer w-1/3"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
