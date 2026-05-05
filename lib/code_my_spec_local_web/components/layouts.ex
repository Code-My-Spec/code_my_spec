defmodule CodeMySpecLocalWeb.Layouts do
  @moduledoc """
  Layout components for the local developer web interface.
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
    <div class="drawer lg:drawer-open min-h-screen">
      <input id="drawer-toggle" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col bg-base-100">
        <div class="navbar bg-base-200 border-b border-base-300">
          <div class="flex-none lg:hidden">
            <label for="drawer-toggle" class="btn btn-square btn-ghost">
              <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="w-5 h-5 stroke-current">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
              </svg>
            </label>
          </div>
          <div class="flex-1 min-w-0">
            <div class="breadcrumbs text-sm px-2 lg:px-6 overflow-hidden">
              <ul>
                <li><.link navigate={~p"/projects"} class="opacity-70 hover:opacity-100">Projects</.link></li>
                <%= if @project do %>
                  <li class="font-semibold">{@project.name}</li>
                  <li :if={@section} class="opacity-70">{section_label(@section)}</li>
                <% end %>
              </ul>
            </div>
          </div>
          <div class="flex-none shrink-0 pr-2">
            <span class="badge badge-sm badge-primary badge-outline uppercase tracking-wider">Local</span>
          </div>
        </div>

        <main class="flex-1 p-6 lg:p-8 max-w-6xl w-full mx-auto">
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side">
        <label for="drawer-toggle" class="drawer-overlay"></label>
        <aside class="w-64 min-h-full bg-base-200 border-r border-base-300 flex flex-col">
          <div class="p-5 border-b border-base-300">
            <.link navigate={~p"/projects"} class="flex items-center gap-2">
              <span class="text-lg font-bold tracking-tight">CodeMySpec</span>
              <span class="badge badge-xs badge-primary">local</span>
            </.link>
          </div>

          <.project_picker project={@project} projects={@projects} />

          <nav class="flex-1 overflow-y-auto px-2 py-3">
            <%= if @project do %>
              <.project_nav project={@project} section={@section} />
            <% else %>
              <.global_nav section={@section} />
            <% end %>
          </nav>
        </aside>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :project, :any, required: true
  attr :projects, :list, required: true

  defp project_picker(assigns) do
    ~H"""
    <div class="p-3 border-b border-base-300">
      <details class="dropdown w-full">
        <summary class="btn btn-sm btn-block justify-between bg-base-300 border-base-300 hover:bg-base-100 normal-case font-normal">
          <span class="truncate">
            {if @project, do: @project.name, else: "Select a project"}
          </span>
          <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" class="w-4 h-4 opacity-60">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" stroke="currentColor" />
          </svg>
        </summary>
        <ul class="menu dropdown-content bg-base-300 rounded-box z-10 mt-1 w-full p-1 shadow-lg max-h-72 overflow-y-auto">
          <li :if={@projects == []}>
            <span class="opacity-60 italic">No local projects</span>
          </li>
          <li :for={p <- @projects}>
            <.link navigate={~p"/projects/#{project_slug(p)}"} class={if @project && @project.id == p.id, do: "menu-active"}>
              <span class="truncate">{p.name}</span>
            </.link>
          </li>
          <li class="border-t border-base-100/30 mt-1 pt-1">
            <.link navigate={~p"/projects"}>
              <span class="opacity-70">All projects →</span>
            </.link>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :project, :any, required: true
  attr :section, :atom, default: nil

  defp project_nav(assigns) do
    ~H"""
    <ul class="menu menu-sm w-full gap-0.5">
      <li class="menu-title pt-1">Workflow</li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/next-task"} active={@section == :next_task}>Next Task</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/files"} active={@section == :files}>Files & Sync</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/configuration"} active={@section == :configuration}>Configuration</.nav_link></li>

      <li class="menu-title pt-3">Data</li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}"} active={@section == :overview}>Overview</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/requirements"} active={@section == :requirements}>Requirements</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/requirements/graph"} active={@section == :requirements_graph}>Requirements Graph</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/components"} active={@section == :components}>Components</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/architecture"} active={@section == :architecture}>Architecture</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/stories"} active={@section == :stories}>Stories</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/issues"} active={@section == :issues}>Issues</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/sessions"} active={@section == :sessions}>Sessions</.nav_link></li>

      <li class="menu-title pt-3">Reference</li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/knowledge"} active={@section == :knowledge}>Knowledge Base</.nav_link></li>
      <li><.nav_link to={~p"/projects/#{project_slug(@project)}/project-knowledge"} active={@section == :project_knowledge}>Project Knowledge</.nav_link></li>
    </ul>
    """
  end

  attr :section, :atom, default: nil

  defp global_nav(assigns) do
    ~H"""
    <ul class="menu menu-sm w-full gap-0.5">
      <li><.nav_link to={~p"/projects"} active={@section == :projects}>All Projects</.nav_link></li>
    </ul>
    """
  end

  attr :to, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@to} class={if @active, do: "menu-active", else: ""}>
      {render_slot(@inner_block)}
    </.link>
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
  defp section_label(:configuration), do: "Configuration"
  defp section_label(:next_task), do: "Next Task"
  defp section_label(:requirements), do: "Requirements"
  defp section_label(:requirements_graph), do: "Requirements Graph"
  defp section_label(:components), do: "Components"
  defp section_label(:architecture), do: "Architecture"
  defp section_label(:stories), do: "Stories"
  defp section_label(:issues), do: "Issues"
  defp section_label(:sessions), do: "Sessions"
  defp section_label(:knowledge), do: "Knowledge Base"
  defp section_label(:project_knowledge), do: "Project Knowledge"
  defp section_label(:projects), do: "Projects"
  defp section_label(other) when is_atom(other), do: other |> Atom.to_string() |> String.capitalize()

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
