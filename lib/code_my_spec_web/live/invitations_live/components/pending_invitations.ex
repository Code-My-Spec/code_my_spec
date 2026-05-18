defmodule CodeMySpecWeb.InvitationsLive.Components.PendingInvitations do
  @moduledoc false
  use CodeMySpecWeb, :live_component

  import CodeMySpecWeb.CoreComponents

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= if Enum.empty?(@invitations) do %>
        <div class="text-center py-8">
          <div class="text-gray-500 text-sm">
            No pending invitations
          </div>
        </div>
      <% else %>
        <div class="overflow-x-auto">
          <.table id="pending-invitations" rows={@invitations}>
            <:col :let={invitation} label="Email">
              {invitation.email}
            </:col>
            <:col :let={invitation} label="Role">
              <span class="capitalize">{invitation.role}</span>
            </:col>
            <:col :let={invitation} label="Invited By">
              {invitation.invited_by.email}
            </:col>
            <:col :let={invitation} label="Date Sent">
              {Calendar.strftime(invitation.inserted_at, "%b %d, %Y")}
            </:col>
            <:col :let={invitation} label="Expires At">
              <span class={[
                expired?(invitation) && "text-warning font-semibold"
              ]}>
                {Calendar.strftime(invitation.expires_at, "%b %d, %Y")}
              </span>
            </:col>
            <:action :let={invitation}>
              <%= if @can_manage and not expired?(invitation) do %>
                <button
                  type="button"
                  phx-click={show_confirm("confirm-cancel-invitation-#{invitation.id}")}
                  class="btn btn-error btn-sm"
                >
                  Cancel
                </button>
                <.confirm_dialog
                  id={"confirm-cancel-invitation-#{invitation.id}"}
                  title="Cancel this invitation?"
                  message={"#{invitation.email} will no longer be able to use this invitation link."}
                  confirm_label="Cancel invitation"
                  cancel_label="Keep it"
                  on_confirm={
                    JS.push("cancel_invitation",
                      value: %{"invitation-id" => invitation.id},
                      target: @myself
                    )
                  }
                />
              <% end %>
            </:action>
          </.table>
        </div>
      <% end %>
    </div>
    """
  end

  # `JS.push value: %{"invitation-id" => id}` from the confirm dialog
  # serializes via JSON, so an integer `id` stays an integer over the
  # wire. The old `data-confirm` flow read the value out of a `phx-value-*`
  # attribute, which is always a string — hence the legacy
  # `String.to_integer/1` call here. Accept both shapes so the handler
  # doesn't crash either way.
  def handle_event("cancel_invitation", %{"invitation-id" => id}, socket) when is_integer(id) do
    send(self(), {:cancel_invitation, id})
    {:noreply, socket}
  end

  def handle_event("cancel_invitation", %{"invitation-id" => id}, socket) when is_binary(id) do
    send(self(), {:cancel_invitation, String.to_integer(id)})
    {:noreply, socket}
  end

  defp expired?(invitation) do
    DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :lt
  end
end
