defmodule CodeMySpecWeb.UserPreferenceLive.Form do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.UserPreferences

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <.header>
        User Preferences
        <:subtitle>Manage your user preferences and settings.</:subtitle>
      </.header>

      <.form for={@form} id="user_preferences-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:active_account_id]} type="number" label="Active account" />
        <.input field={@form[:active_project_id]} type="number" label="Active project" />
        <.input field={@form[:token]} type="text" label="Token" readonly />
        <footer>
          <.button phx-disable-with="Saving...">Save Preferences</.button>
          <.button type="button" phx-click="generate_token">Generate New Token</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    changeset = UserPreferences.change_user_preferences(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"user_preference" => user_preference_params}, socket) do
    changeset =
      UserPreferences.change_user_preferences(
        socket.assigns.current_scope,
        user_preference_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"user_preference" => user_preference_params}, socket) do
    case UserPreferences.get_user_preference(socket.assigns.current_scope) do
      {:ok, _user_preference} ->
        update_user_preferences(socket, user_preference_params)

      {:error, :not_found} ->
        create_user_preferences(socket, user_preference_params)
    end
  end

  def handle_event("generate_token", _params, socket) do
    case UserPreferences.generate_token(socket.assigns.current_scope) do
      {:ok, _user_preference} ->
        changeset = UserPreferences.change_user_preferences(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Token generated successfully")
         |> assign(:form, to_form(changeset))}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp update_user_preferences(socket, user_preference_params) do
    case UserPreferences.update_user_preferences(
           socket.assigns.current_scope,
           user_preference_params
         ) do
      {:ok, _user_preference} ->
        {:noreply,
         socket
         |> put_flash(:info, "User preferences updated successfully")
         |> assign(
           :form,
           to_form(UserPreferences.change_user_preferences(socket.assigns.current_scope))
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp create_user_preferences(socket, user_preference_params) do
    case UserPreferences.create_user_preferences(
           socket.assigns.current_scope,
           user_preference_params
         ) do
      {:ok, _user_preference} ->
        {:noreply,
         socket
         |> put_flash(:info, "User preferences created successfully")
         |> assign(
           :form,
           to_form(UserPreferences.change_user_preferences(socket.assigns.current_scope))
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
