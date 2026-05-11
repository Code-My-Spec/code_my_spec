defmodule CodeMySpecWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app-zone drawer lg:drawer-open min-h-screen">
      <input id="drawer-toggle" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col bg-base-100">
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
            <div class="breadcrumbs text-sm px-2 lg:px-8 overflow-hidden">
              <ul>
                <%= if @current_scope do %>
                  <li><.account_breadcrumb scope={@current_scope} current_path={@current_path} /></li>
                  <li><.project_breadcrumb scope={@current_scope} current_path={@current_path} /></li>
                <% end %>
              </ul>
            </div>
          </div>
          <div class="flex-none shrink-0">
            <button
              id="enable-notifications-btn"
              phx-click={JS.dispatch("phx:toggle-push-notifications")}
              class="btn btn-ghost btn-sm tooltip tooltip-bottom"
              data-tip="Enable notifications"
              data-subscribed="false"
            >
              <span data-notif-icon-off><.icon name="hero-bell" class="size-5" /></span>
              <span data-notif-icon-on class="hidden"><.icon name="hero-bell-alert-solid" class="size-5 text-primary" /></span>
            </button>
          </div>
        </div>

        <main class="flex-1 p-6">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side">
        <label for="drawer-toggle" class="drawer-overlay"></label>
        <aside class="w-64 min-h-full bg-base-200">
          <div class="p-6 border-b border-base-300">
            <a href={~p"/app"} class="flex items-center gap-3">
              <img src={~p"/images/logo.svg"} alt="CodeMySpec" class="h-6 w-6" />
              <span class="text-lg font-semibold">CodeMySpec</span>
            </a>
          </div>
          <ul class="menu p-4 w-64 min-h-full text-base-content">
            <li><a href={~p"/app"}>Overview</a></li>
            <%!--
              Audit S2: during the onboarding ladder (no project linked OR CLI
              has never connected), every deep nav link is a derailment surface
              — Projects/Issues/Content/Accounts/Settings either show empty
              states or unrelated screens that pull the user out of setup.
              Hide them until the user has actually activated.
            --%>
            <%= if onboarding_complete?(@current_scope) do %>
              <li><a href={~p"/app/projects"}>Projects</a></li>
              <li><a href={~p"/app/issues"}>Issues</a></li>
              <li><a href={~p"/app/content_admin"}>Content</a></li>
              <li class="mt-auto"><a href={~p"/app/accounts"}>Accounts</a></li>
              <li><a href={~p"/app/users/settings"}>Settings</a></li>
            <% end %>
            <%= if @current_scope do %>
              <li class={if onboarding_complete?(@current_scope), do: "border-t border-base-300 mt-2 pt-2", else: "mt-auto border-t border-base-300 pt-2"}>
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

  # True once the user has finished the onboarding ladder enough that
  # the full sidebar is useful — they have a project linked AND a CLI
  # has connected at least once. Until both are true, deep nav links
  # are dead ends and we hide them (audit S2).
  defp onboarding_complete?(nil), do: false

  defp onboarding_complete?(%{
         user: %{cli_first_connected_at: %DateTime{}},
         active_project: %{__struct__: _}
       }),
       do: true

  defp onboarding_complete?(_), do: false

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

      <Layouts.marketing flash={@flash}>
        <h1>Content</h1>
      </Layouts.marketing>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :page_title, :string, default: "CodeMySpec"

  slot :inner_block, required: true

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  def marketing(assigns) do
    ~H"""
    <div class="drawer">
      <input id="marketing-drawer-toggle" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content min-h-screen flex flex-col">
        <!-- Navbar — hamburger toggles the drawer on <lg; on lg+ the nav renders
             inline with a Products submenu (DaisyUI menu details/summary). -->
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
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
                </svg>
              </label>
              <a href={~p"/"} class="btn btn-ghost text-xl normal-case px-2">
                <img src={~p"/images/logo.svg"} alt="CodeMySpec" class="h-8 w-8" width="32" height="32" />
                <span class="hidden sm:inline">CodeMySpec</span>
              </a>
            </div>
            <div class="navbar-center hidden lg:flex">
              <ul class="menu menu-horizontal menu-md px-1">
                <li>
                  <details>
                    <summary>Products</summary>
                    <ul class="bg-base-200 rounded-box w-48 z-10">
                      <li><.link href={~p"/products/code-my-spec"}>CodeMySpec</.link></li>
                      <li><.link href={~p"/products/market-my-spec"}>MarketMySpec</.link></li>
                    </ul>
                  </details>
                </li>
                <li><.link href={~p"/methodology"}>Method</.link></li>
                <li><.link href={~p"/blog"}>Blog</.link></li>
                <li><.link href={~p"/documentation"}>Docs</.link></li>
              </ul>
            </div>
            <div class="navbar-end gap-1 sm:gap-2">
              <%= if @current_scope do %>
                <span class="hidden">{@current_scope.user.email}</span>
                <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost hidden sm:inline-flex">Log out</.link>
                <.link href={~p"/app"} class="btn btn-primary">Open workspace</.link>
              <% else %>
                <.link href={~p"/users/log-in"} class="btn btn-ghost hidden sm:inline-flex">Log in</.link>
                <.link href={~p"/users/register"} class="btn btn-primary">Register</.link>
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
                <li><a href="/methodology" class="hover:text-primary transition-colors">Methodology</a></li>
                <li><a href="/case-studies" class="hover:text-primary transition-colors">Case Studies</a></li>
                <li><a href="/users/register" class="hover:text-primary transition-colors">Get Started</a></li>
              </ul>
            </div>
            <div>
              <h4 class="font-bold text-sm mb-3 text-base-content">Content</h4>
              <ul class="space-y-2 text-sm text-base-content/70">
                <li><a href="/blog" class="hover:text-primary transition-colors">Blog</a></li>
                <li><a href="/documentation" class="hover:text-primary transition-colors">Documentation</a></li>
                <li><a href="/pages" class="hover:text-primary transition-colors">Pages</a></li>
                <li><a href="/pages/founder-story" class="hover:text-primary transition-colors">Founder Story</a></li>
                <li><a href="/pages/about" class="hover:text-primary transition-colors">About</a></li>
              </ul>
            </div>
            <div>
              <h4 class="font-bold text-sm mb-3 text-base-content">Legal</h4>
              <ul class="space-y-2 text-sm text-base-content/70">
                <li><a href="/pages/privacy-policy" class="hover:text-primary transition-colors">Privacy Policy</a></li>
                <li><a href="/pages/terms-of-service" class="hover:text-primary transition-colors">Terms of Service</a></li>
                <li><a href="/pages/end-user-license-agreement" class="hover:text-primary transition-colors">EULA</a></li>
              </ul>
            </div>
            <div>
              <h4 class="font-bold text-sm mb-3 text-base-content">Connect</h4>
              <ul class="space-y-2 text-sm text-base-content/70">
                <li><a href="https://github.com/code-my-spec" target="_blank" rel="noopener noreferrer" class="hover:text-primary transition-colors">GitHub</a></li>
                <li><a href="https://www.linkedin.com/in/john-davenport-software/" target="_blank" rel="noopener noreferrer" class="hover:text-primary transition-colors">LinkedIn</a></li>
                <li><a href="https://x.com/johns10d" target="_blank" rel="noopener noreferrer" class="hover:text-primary transition-colors">X / Twitter</a></li>
                <li><a href="https://www.youtube.com/@codemyspec" target="_blank" rel="noopener noreferrer" class="hover:text-primary transition-colors">YouTube</a></li>
              </ul>
            </div>
          </div>
          <div class="border-t border-base-300 pt-6 flex flex-col sm:flex-row justify-between items-center gap-2 text-sm text-base-content/50">
            <div>© {Date.utc_today().year} CodeMySpec</div>
            <div>Built for Phoenix devs who actually care about architecture.</div>
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
            <li>
              <details open>
                <summary>Products</summary>
                <ul>
                  <li><.link href={~p"/products/code-my-spec"}>CodeMySpec</.link></li>
                  <li><.link href={~p"/products/market-my-spec"}>MarketMySpec</.link></li>
                </ul>
              </details>
            </li>
            <li><.link href={~p"/methodology"}>Method</.link></li>
            <li><.link href={~p"/blog"}>Blog</.link></li>
            <li><.link href={~p"/documentation"}>Docs</.link></li>
          </ul>
          <div class="p-4 border-t border-base-300 flex flex-col gap-2">
            <%= if @current_scope do %>
              <div class="text-xs opacity-60 px-1 truncate" title={@current_scope.user.email}>
                {@current_scope.user.email}
              </div>
              <.link href={~p"/app"} class="btn btn-primary btn-block">Open workspace</.link>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-block">Log out</.link>
            <% else %>
              <.link href={~p"/users/log-in"} class="btn btn-ghost btn-block">Log in</.link>
              <.link href={~p"/users/register"} class="btn btn-primary btn-block">Register</.link>
            <% end %>
          </div>
        </aside>
      </div>
    </div>
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
