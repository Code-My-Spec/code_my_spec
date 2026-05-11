defmodule CodeMySpecWeb.AccountLive.Picker do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Accounts.MembersRepository
  alias CodeMySpec.UserPreferences

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center min-h-screen px-4">
      <div class="w-full max-w-md">
        <.header>
          Select Account
          <:subtitle>Choose which account you'd like to work with</:subtitle>
        </.header>

        <div class="mt-8">
          <ul class="menu bg-base-200 rounded-box w-full">
            <li
              :for={account <- @accounts}
              class={if account.id == @current_account_id, do: "bordered", else: ""}
            >
              <a
                phx-click="account-selected"
                phx-value-account-id={account.id}
                class={if account.id == @current_account_id, do: "active", else: ""}
              >
                <div class="flex-1">
                  <div class="font-semibold">{account.name}</div>
                  <div :if={@user_roles[account.id]} class="text-sm opacity-70">
                    {String.capitalize(to_string(@user_roles[account.id]))}
                  </div>
                </div>
                <div :if={account.id == @current_account_id} class="badge badge-primary">
                  Current
                </div>
              </a>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    current_scope = socket.assigns.current_scope
    accounts = Accounts.list_accounts(current_scope)
    current_account_id = current_scope.active_account_id
    return_to = params["return_to"] || "/"

    # Build a map of account_id -> user_role so the picker can show
    # the user's role on each account they belong to.
    user_roles =
      accounts
      |> Enum.into(%{}, fn account ->
        {account.id, get_user_role(account.id, current_scope.user.id)}
      end)

    {:ok,
     socket
     |> assign(:accounts, accounts)
     |> assign(:current_account_id, current_account_id)
     |> assign(:user_roles, user_roles)
     |> assign(:return_to, return_to)}
  end

  @impl true
  def handle_event("account-selected", %{"account-id" => account_id}, socket) do
    current_scope = socket.assigns.current_scope

    # Validate that the user has access to this account
    if Enum.any?(socket.assigns.accounts, &(&1.id == account_id)) do
      case UserPreferences.select_active_account(current_scope, account_id) do
        {:ok, _user_preference} ->
          {:noreply,
           socket
           |> put_flash(:info, "Account selected successfully")
           |> push_navigate(to: "/app")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to select account")}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "You don't have access to this account")}
    end
  end

  # Helper function to get user role for team accounts
  defp get_user_role(account_id, user_id) do
    case MembersRepository.get_user_role(user_id, account_id) do
      # Default fallback
      nil -> :member
      role -> role
    end
  end
end
