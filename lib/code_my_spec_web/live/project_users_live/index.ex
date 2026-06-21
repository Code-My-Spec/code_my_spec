defmodule CodeMySpecWeb.ProjectUsersLive.Index do
  @moduledoc """
  Lists the users registered for a project's target application, read live via
  the project's deploy key. The index of the ProjectUsers resource — a future
  `ProjectUsersLive.Show` will hold per-user enriched / ICP data.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.ProjectUsers
  alias CodeMySpec.Projects

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Registered users
        <:subtitle>People who have registered for {@project.name}.</:subtitle>
      </.header>

      {render_body(assigns)}
    </Layouts.app>
    """
  end

  defp render_body(%{error: nil} = assigns) do
    ~H"""
    <div data-test="users-list">
      <table class="table">
        <thead>
          <tr>
            <th>Email</th>
            <th>Registered</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={user <- @page.users} data-test="user-row">
            <td data-test="user-email">{user.email}</td>
            <td data-test="user-registered-at">{format_registered_at(user.registered_at)}</td>
          </tr>
        </tbody>
      </table>

      <div class="mt-4 flex items-center gap-2">
        <.button :if={@page.page > 1} phx-click="prev_page" data-test="users-prev-page">
          Previous
        </.button>
        <span data-test="users-page-indicator">Page {@page.page}</span>
        <.button :if={more_pages?(@page)} phx-click="next_page" data-test="users-next-page">
          Next page
        </.button>
      </div>
    </div>
    """
  end

  defp render_body(%{error: :not_configured} = assigns) do
    ~H"""
    <p data-test="users-error">
      Configure a client API URL and deploy key on this project to see the users
      who registered for your application.
    </p>
    """
  end

  defp render_body(%{error: :unauthorized} = assigns) do
    ~H"""
    <p data-test="users-error">
      Your application rejected the deploy key — authentication failed. Check that
      the deploy key here matches the one your application expects.
    </p>
    """
  end

  defp render_body(%{error: :unreachable} = assigns) do
    ~H"""
    <p data-test="users-error">
      We could not reach your application. Check that it is running and the client
      API URL is correct.
    </p>
    """
  end

  defp render_body(assigns) do
    ~H"""
    <p data-test="users-error">Something went wrong loading your registered users.</p>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    project = Projects.get_project!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:page_title, "Registered users")
     |> assign(:project, project)
     |> load_users(1)}
  end

  @impl true
  def handle_event("next_page", _params, socket) do
    {:noreply, load_users(socket, socket.assigns.page.page + 1)}
  end

  @impl true
  def handle_event("prev_page", _params, socket) do
    {:noreply, load_users(socket, max(socket.assigns.page.page - 1, 1))}
  end

  defp load_users(socket, page_number) do
    case ProjectUsers.list_registered_users(socket.assigns.project, page_number) do
      {:ok, page} -> socket |> assign(:page, page) |> assign(:error, nil)
      {:error, reason} -> socket |> assign(:page, nil) |> assign(:error, reason)
    end
  end

  defp more_pages?(page), do: page.page * page.page_size < page.total

  defp format_registered_at(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%Y-%m-%d")
  defp format_registered_at(_), do: "—"
end
