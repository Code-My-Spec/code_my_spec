defmodule CodeMySpecWeb.PermissionLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Notifications

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

  def handle_event("approve", _params, socket) do
    resolve(socket, "allow")
  end

  def handle_event("deny", _params, socket) do
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-lg mx-auto">
        <%= if @request do %>
          <div class="card bg-base-200 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-2xl">
                Claude Code Permission Request
              </h2>

              <div class="mt-4 space-y-3">
                <div>
                  <span class="text-sm font-semibold opacity-70">Tool</span>
                  <p class="text-lg font-mono">{@request.tool_name}</p>
                </div>

                <div>
                  <span class="text-sm font-semibold opacity-70">Details</span>
                  <pre class="bg-base-300 rounded-lg p-3 text-sm overflow-x-auto mt-1"><code>{format_input(@request.tool_name, @request.tool_input)}</code></pre>
                </div>

                <div>
                  <span class="text-sm font-semibold opacity-70">Status</span>
                  <span class={[
                    "badge ml-2",
                    status_badge_class(@request.status)
                  ]}>
                    {@request.status}
                  </span>
                </div>

                <div class="text-xs opacity-50">
                  Requested {Calendar.strftime(@request.inserted_at, "%H:%M:%S")}
                </div>
              </div>

              <%= if @request.status == "pending" do %>
                <div class="card-actions justify-end mt-6 gap-3">
                  <button
                    type="button"
                    phx-click={show_confirm("confirm-deny-request")}
                    class="btn btn-error btn-lg"
                  >
                    Deny
                  </button>
                  <button
                    phx-click="approve"
                    class="btn btn-success btn-lg"
                  >
                    Approve
                  </button>
                  <.confirm_dialog
                    id="confirm-deny-request"
                    title="Deny this request?"
                    confirm_label="Deny"
                    on_confirm={JS.push("deny")}
                  />
                </div>
              <% else %>
                <div class="mt-6 text-center opacity-70">
                  This request has been resolved.
                </div>
              <% end %>
            </div>
          </div>
        <% else %>
          <div class="text-center py-12 opacity-70">
            Permission request not found or not authorized.
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp format_input("Bash", %{"command" => cmd}), do: cmd
  defp format_input("Read", %{"file_path" => path}), do: path
  defp format_input("Write", %{"file_path" => path}), do: path
  defp format_input("Edit", %{"file_path" => path}), do: path
  defp format_input(_tool, input), do: Jason.encode!(input, pretty: true)

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("approved"), do: "badge-success"
  defp status_badge_class("denied"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"
end
