defmodule CodeMySpecWeb.ConsoleLive.Components.EnvironmentSwitcher do
  @moduledoc """
  dev/uat/prod, Railway-style — a `?env=` patch, not a navigate, so
  switching environments does not remount the page.

  Only shown on the sections `?env=` actually scopes (Overview, Resources,
  Deploys); Secrets, Credentials and Settings are project-wide.
  """

  use CodeMySpecWeb, :html

  attr :environment, :string, required: true
  attr :environments, :list, required: true
  attr :base_path, :string, required: true
  attr :live_action, :atom, required: true

  def environment_switcher(assigns) do
    ~H"""
    <div data-test="environment-switcher" role="tablist" class="tabs tabs-boxed">
      <.link
        :for={env <- @environments}
        patch={switch_path(@base_path, @live_action, env)}
        data-test="environment-switcher-tab"
        data-environment={env}
        role="tab"
        class={["tab", env == @environment && "tab-active"]}
      >
        {env}
      </.link>
    </div>
    """
  end

  defp switch_path(base_path, :resources, env), do: "#{base_path}/resources?env=#{env}"
  # Switching environments from a single resource's detail returns to the
  # resources list for the new environment — there is no guarantee the same
  # resource key applies to a step scoped to the one being left.
  defp switch_path(base_path, :resource_detail, env), do: "#{base_path}/resources?env=#{env}"
  defp switch_path(base_path, :deploys, env), do: "#{base_path}/deploys?env=#{env}"
  defp switch_path(base_path, _overview, env), do: "#{base_path}?env=#{env}"
end
