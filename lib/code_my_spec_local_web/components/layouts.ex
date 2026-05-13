defmodule CodeMySpecLocalWeb.Layouts do
  @moduledoc """
  Local app layout — shares the codemyspec dark theme with the cloud
  bundle. Structure mirrors the LocalShell mockup in
  `~/Downloads/Local App Design/components.jsx`:

    * `local-header`     — logo + `● local` pill on left, breadcrumb on right
    * `local-prompt-strip` — terminal-style cwd hint when a project is active
    * `local-sidebar`    — workshop posture (always visible per UX direction)
    * main pane           — scanline-textured dark canvas

  The mobile drawer-toggle is preserved so the sidebar collapses on
  narrow viewports.
  """
  use CodeMySpecLocalWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :project, :any, default: nil, doc: "current project, or nil on project-less pages"
  attr :projects, :list, default: [], doc: "list of all local projects for the picker"
  attr :section, :atom, default: nil, doc: "which sidebar section is active"
  attr :page_title, :string, default: "CodeMySpec Local"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="local-zone scanlines drawer lg:drawer-open min-h-screen">
      <input id="drawer-toggle" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col min-w-0">
        <header class="local-header">
          <div class="flex items-center justify-between px-6 py-3.5 gap-3">
            <div class="flex items-center gap-3.5 min-w-0">
              <label for="drawer-toggle" class="btn btn-square btn-ghost btn-sm lg:hidden" aria-label="Open navigation">
                <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="w-5 h-5 stroke-current">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
                </svg>
              </label>
              <.link navigate={~p"/projects"} class="local-logo">CodeMySpec</.link>
              <span class="local-pill">local</span>
            </div>
            <.header_breadcrumb project={@project} section={@section} />
          </div>
          <div :if={@project} class="local-prompt-strip">
            <span class="arrow">▸</span>
            <span>{prompt_cwd(@project)}</span>
            <span class="sep">::</span>
            <span class="path">{section_path(@section)}</span>
          </div>
        </header>

        <main class="flex-1 overflow-auto px-6 lg:px-8 py-8 max-w-6xl w-full mx-auto">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side">
        <label for="drawer-toggle" class="drawer-overlay"></label>
        <aside class="local-sidebar min-h-full flex flex-col">
          <%!--
            Audit re-pass §2c: the `// project` block only makes sense when
            a project is active. On the empty-state `/projects` page it
            duplicated the `// workspace` section's "All projects" link, so
            hide the block entirely when there's no active project.
          --%>
          <%= if @project do %>
            <.sidebar_project_block project={@project} projects={@projects} />
            <.sidebar_project_nav project={@project} section={@section} />
          <% else %>
            <.sidebar_global_nav section={@section} />
          <% end %>
        </aside>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :project, :any, required: true
  attr :section, :atom, default: nil

  defp header_breadcrumb(assigns) do
    ~H"""
    <nav class="local-breadcrumb shrink min-w-0 overflow-hidden">
      <%= if @project do %>
        <.link navigate={~p"/projects"} class="crumb hover:text-base-content">projects</.link>
        <span class="sep">/</span>
        <span class={"crumb truncate #{if !@section, do: "is-last"}"}>{@project.name}</span>
        <%= if @section do %>
          <span class="sep">/</span>
          <span class="crumb is-last truncate">{section_label(@section)}</span>
        <% end %>
      <% else %>
        <span class="crumb is-last">projects</span>
      <% end %>
    </nav>
    """
  end

  attr :project, :any, required: true
  attr :projects, :list, required: true

  # The project block doubles as the picker — clicking the project name
  # opens a list of all linked projects (or "All projects" when none).
  defp sidebar_project_block(assigns) do
    ~H"""
    <div class="local-sidebar-project">
      <div class="local-sidebar-project-label">// project</div>
      <%= if @project do %>
        <details class="dropdown w-full">
          <summary class="local-sidebar-project-name list-none cursor-pointer truncate" role="button" aria-label="Switch project">
            {@project.name}
          </summary>
          <ul class="menu dropdown-content bg-base-300 z-10 mt-2 w-full p-1 max-h-72 overflow-y-auto border border-base-content/10">
            <li :for={p <- @projects}>
              <.link navigate={~p"/projects/#{project_slug(p)}"} class={if @project.id == p.id, do: "menu-active"}>
                <span class="truncate">{p.name}</span>
              </.link>
            </li>
            <li class="border-t border-base-content/10 mt-1 pt-1">
              <.link navigate={~p"/projects"}>
                <span class="opacity-70">All projects →</span>
              </.link>
            </li>
          </ul>
        </details>
        <div class="local-sidebar-project-slug">{project_slug(@project)}</div>
      <% else %>
        <.link navigate={~p"/projects"} class="local-sidebar-project-name block hover:opacity-80">
          All projects →
        </.link>
      <% end %>
    </div>
    """
  end

  attr :project, :any, required: true
  attr :section, :atom, default: nil

  defp sidebar_project_nav(assigns) do
    ~H"""
    <div class="local-sidebar-section">
      <div class="local-sidebar-eyebrow">// workflow</div>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/next-task"} active={@section == :next_task}>Next task</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/files"} active={@section == :files}>Files &amp; sync</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/problems"} active={@section == :problems}>Problems</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/configuration"} active={@section == :configuration}>Configuration</.sidebar_item>
    </div>

    <div class="local-sidebar-section">
      <div class="local-sidebar-eyebrow">// data</div>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}"} active={@section == :overview}>Overview</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/stories"} active={@section == :stories}>Stories</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/stories/scheduler"} active={@section == :scheduler}>Scheduler</.sidebar_item>
      <.sidebar_group
        label="Requirements"
        active={@section in [:requirements, :requirements_stories, :requirements_graph]}
      >
        <.sidebar_item to={~p"/projects/#{project_slug(@project)}/requirements"} active={@section == :requirements}>Project</.sidebar_item>
        <.sidebar_item to={~p"/projects/#{project_slug(@project)}/requirements/stories"} active={@section == :requirements_stories}>Stories</.sidebar_item>
        <.sidebar_item to={~p"/projects/#{project_slug(@project)}/requirements/graph"} active={@section == :requirements_graph}>Graph</.sidebar_item>
      </.sidebar_group>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/personas"} active={@section == :personas}>Personas</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/issues"} active={@section == :issues}>Issues</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/sessions"} active={@section == :sessions}>Sessions</.sidebar_item>
    </div>

    <div class="local-sidebar-section">
      <div class="local-sidebar-eyebrow">// reference</div>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/knowledge"} active={@section == :knowledge}>Knowledge base</.sidebar_item>
      <.sidebar_item to={~p"/projects/#{project_slug(@project)}/project-knowledge"} active={@section == :project_knowledge}>Project knowledge</.sidebar_item>
    </div>
    """
  end

  attr :section, :atom, default: nil

  defp sidebar_global_nav(assigns) do
    ~H"""
    <div class="local-sidebar-section">
      <div class="local-sidebar-eyebrow">// workspace</div>
      <.sidebar_item to={~p"/projects"} active={@section == :projects}>All projects</.sidebar_item>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp sidebar_item(assigns) do
    ~H"""
    <.link navigate={@to} class={"local-sidebar-item #{if @active, do: "is-active"}"}>
      <span :if={!@active} class="item-prefix"></span>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # Collapsible sidebar group — <details>/<summary> driven by `active`
  # (open when any child section is the current page). The summary
  # styles like a top-level sidebar_item; child items render indented
  # in the .local-sidebar-sub stripe.
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp sidebar_group(assigns) do
    ~H"""
    <details class="local-sidebar-group" open={@active}>
      <summary class={"local-sidebar-item #{if @active, do: "is-active"}"}>
        <span :if={!@active} class="item-prefix"></span>
        {@label}
        <span class="group-caret">▸</span>
      </summary>
      <div class="local-sidebar-sub">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" class="toast toast-top toast-end z-50">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :kind, :atom, required: true
  attr :flash, :map, required: true

  defp flash(assigns) do
    msg = Phoenix.Flash.get(assigns.flash, assigns.kind)
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div :if={@msg} id={@id} role="alert" class={"alert #{flash_class(@kind)} shadow-lg"} phx-click={Phoenix.LiveView.JS.hide(to: "##{@id}")}>
      <span>{@msg}</span>
    </div>
    """
  end

  defp flash_class(:info), do: "alert-info"
  defp flash_class(:error), do: "alert-error"
  defp flash_class(_), do: ""

  defp section_label(:overview), do: "Overview"
  defp section_label(:files), do: "Files & Sync"
  defp section_label(:problems), do: "Problems"
  defp section_label(:configuration), do: "Configuration"
  defp section_label(:next_task), do: "Next Task"
  defp section_label(:requirements), do: "Requirements"
  defp section_label(:requirements_stories), do: "Requirements / Stories"
  defp section_label(:requirements_graph), do: "Requirements Graph"
  defp section_label(:stories), do: "Stories"
  defp section_label(:scheduler), do: "Scheduler"
  defp section_label(:personas), do: "Personas"
  defp section_label(:issues), do: "Issues"
  defp section_label(:sessions), do: "Sessions"
  defp section_label(:knowledge), do: "Knowledge Base"
  defp section_label(:project_knowledge), do: "Project Knowledge"
  defp section_label(:projects), do: "Projects"
  defp section_label(other) when is_atom(other), do: other |> Atom.to_string() |> String.capitalize()
  defp section_label(nil), do: nil

  defp section_path(nil), do: "/overview"
  defp section_path(section) do
    section
    |> Atom.to_string()
    |> String.replace("_", "-")
    |> then(&("/" <> &1))
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # The prompt strip is styled like a shell prompt, so users will read it
  # as their working directory. Show the real `local_path` (abbreviated to
  # `~/…` when it lives under $HOME) when we have one — falling back to a
  # branded `~/code/<slug>` only if the project hasn't been linked yet
  # (e.g. during the per-project ladder's init rung).
  defp prompt_cwd(project) do
    case project.local_path do
      nil -> "~/code/#{project_slug(project)}"
      "" -> "~/code/#{project_slug(project)}"
      path -> abbreviate_home(path)
    end
  end

  defp abbreviate_home(path) do
    case safe_home() do
      nil ->
        path

      home ->
        if String.starts_with?(path, home) do
          "~" <> String.replace_prefix(path, home, "")
        else
          path
        end
    end
  end

  defp safe_home do
    System.user_home()
  rescue
    _ -> nil
  end
end
