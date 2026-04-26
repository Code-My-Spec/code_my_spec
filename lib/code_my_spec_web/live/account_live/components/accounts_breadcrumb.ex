defmodule CodeMySpecWeb.AccountLive.Components.AccountsBreadcrumb do
  @moduledoc false
  use CodeMySpecWeb, :html

  @doc """
  Renders an account breadcrumb component.

  Shows the current account name with a link to switch accounts.
  Displays "Select Account" if no account is currently selected.

  ## Example

      <.account_breadcrumb scope={@scope} />

  """
  attr :scope, :map, required: true, doc: "Current user scope with active account"
  attr :current_path, :string, default: "/"

  def account_breadcrumb(assigns) do
    assigns =
      assign_new(assigns, :current_account, fn ->
        if assigns.scope.active_account_id do
          CodeMySpec.Accounts.get_account(assigns.scope, assigns.scope.active_account_id)
        else
          nil
        end
      end)

    ~H"""
    <div class="breadcrumbs text-sm">
      <ul>
        <li>
          <.link navigate={~p"/app/accounts/picker?return_to=#{@current_path}"}>
            <%= if @current_account do %>
              {@current_account.name}
            <% else %>
              Select Account
            <% end %>
          </.link>
        </li>
      </ul>
    </div>
    """
  end
end
