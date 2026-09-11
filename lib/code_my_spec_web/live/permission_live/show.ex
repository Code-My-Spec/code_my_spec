defmodule CodeMySpecWeb.PermissionLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Notifications
  alias CodeMySpecWeb.PermissionComponents

  def mount(%{"id" => id}, _session, socket) do
    case Notifications.get_permission_request(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Permission request not found")
         |> assign(page_title: "Not Found", request: nil)}

      request ->
        if request.user_id != socket.assigns.current_scope.user.id do
          {:ok,
           socket
           |> put_flash(:error, "Not authorized")
           |> assign(page_title: "Not Authorized", request: nil)}
        else
          {:ok,
           assign(socket,
             page_title: "Approve: #{request.tool_name}",
             request: request
           )}
        end
    end
  end

  def handle_event("approve", %{"id" => _id}, socket) do
    resolve(socket, "allow")
  end

  def handle_event("deny", %{"id" => _id}, socket) do
    resolve(socket, "deny")
  end

  defp resolve(socket, decision) do
    request = socket.assigns.request

    case Notifications.resolve_permission_request(request.id, decision) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(request: updated)
         |> put_flash(:info, "#{String.capitalize(decision)}ed")}

      {:error, {:already_resolved, _}} ->
        # Reload to show current state
        updated = Notifications.get_permission_request(request.id)

        {:noreply,
         socket
         |> assign(request: updated)
         |> put_flash(:info, "Already resolved")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="max-w-lg mx-auto">
        <%= if @request do %>
          <PermissionComponents.permission_request
            id={"permission-#{@request.id}"}
            request={@request}
            on_approve="approve"
            on_deny="deny"
          />
        <% else %>
          <div class="text-center py-12 opacity-70">
            Permission request not found or not authorized.
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
