defmodule CodeMySpecWeb.AccountLive.Components.Navigation do
  @moduledoc false
  use CodeMySpecWeb, :live_component

  alias CodeMySpec.Authorization

  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@account.name}
        <:subtitle>Account settings and member management</:subtitle>
      </.header>

      <div class="mt-8">
        <div class="tabs tabs-boxed">
          <.link
            patch={~p"/app/accounts/#{@account.id}/manage"}
            class={["tab", if(@active_tab == :manage, do: "tab-active")]}
          >
            Manage
          </.link>
          <.link
            patch={~p"/app/accounts/#{@account.id}/members"}
            class={["tab", if(@active_tab == :members, do: "tab-active")]}
          >
            Members
          </.link>
          <.link
            :if={can_manage_members?(@current_scope, @account)}
            patch={~p"/app/accounts/#{@account.id}/invitations"}
            class={["tab", if(@active_tab == :invitations, do: "tab-active")]}
          >
            Invitations
          </.link>
          <.link
            :if={can_manage_members?(@current_scope, @account)}
            patch={~p"/app/accounts/#{@account.id}/agents"}
            class={["tab", if(@active_tab == :agents, do: "tab-active")]}
          >
            Agents
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp can_manage_members?(scope, account) do
    Authorization.authorize(:manage_members, scope, account.id)
  end
end
