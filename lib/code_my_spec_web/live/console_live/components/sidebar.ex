defmodule CodeMySpecWeb.ConsoleLive.Components.Sidebar do
  @moduledoc """
  The console's section navigation — Overview, Resources, Servers, Inventory,
  Deploys, Secrets, Credentials, Activity, Settings. A plain function component; `ConsoleLive`
  carries all the state.
  """

  use CodeMySpecWeb, :html

  attr :live_action, :atom, required: true
  attr :project_id, :any, required: true

  def sidebar(assigns) do
    ~H"""
    <ul data-test="console-sidebar" class="menu bg-base-200 min-h-full w-56 p-4 gap-1">
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console"}
          data-test="console-nav-overview"
          class={nav_class(@live_action, :overview)}
        >
          Overview
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/resources"}
          data-test="console-nav-resources"
          class={nav_class(@live_action, :resources)}
        >
          Resources
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/servers"}
          data-test="console-nav-servers"
          class={nav_class(@live_action, :servers)}
        >
          Servers
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/inventory"}
          data-test="console-nav-inventory"
          class={nav_class(@live_action, :inventory)}
        >
          Inventory
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/deploys"}
          data-test="console-nav-deploys"
          class={nav_class(@live_action, :deploys)}
        >
          Deploys
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/secrets"}
          data-test="console-nav-secrets"
          class={nav_class(@live_action, :secrets)}
        >
          Secrets
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/credentials"}
          data-test="console-nav-credentials"
          class={nav_class(@live_action, :credentials)}
        >
          Credentials
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/activity"}
          data-test="console-nav-activity"
          class={nav_class(@live_action, :activity)}
        >
          Activity
        </.link>
      </li>
      <li>
        <.link
          navigate={~p"/app/projects/#{@project_id}/console/settings"}
          data-test="console-nav-settings"
          class={nav_class(@live_action, :settings)}
        >
          Settings
        </.link>
      </li>
    </ul>
    """
  end

  defp nav_class(:resource_detail, :resources), do: "menu-active"
  defp nav_class(live_action, section) when live_action == section, do: "menu-active"
  defp nav_class(_live_action, _section), do: nil
end
