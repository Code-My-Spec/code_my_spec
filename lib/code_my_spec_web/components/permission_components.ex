defmodule CodeMySpecWeb.PermissionComponents do
  @moduledoc """
  A permission/tap-out request the agent raised, resolvable where it is shown.

  Lifted out of `PermissionLive.Show`, the same move `ChatComponents.question/1`
  already made — the standalone page was the only place this ever rendered, and
  a request an agent raised belongs beside the work that raised it just as much
  as a question does.

  Resolved requests keep rendering, showing what was asked and what was
  decided — never removed from the list they came from. A caller that renders
  several of these at once (the notification dropdown, an agent's own
  conversation) depends on that: if resolving one removed its DOM node, a
  CSS-only `:focus-within` dropdown would lose focus and close itself,
  including on every other request still pending.

  `on_approve`/`on_deny` name the event because hosts handle it differently — a
  page holding one request, a transcript or dropdown that may hold several. The
  buttons carry the request's own id (`phx-value-id`) so a host with more than
  one pending request can tell them apart without keeping its own single
  `@request` assign the way the standalone page does. `target` is `phx-target`
  verbatim — nil for a page or LiveView, `@myself` for a host embedding this
  inside a stateful `LiveComponent`. Deny's confirmation dialog needs it baked
  into the confirm button's own `JS.push` rather than as a sibling HTML
  attribute, since `confirm_dialog` only ever renders the one button it owns.
  """
  use Phoenix.Component

  import CodeMySpecWeb.ChatComponents, only: [local_time: 1]
  import CodeMySpecWeb.CoreComponents, only: [icon: 1, confirm_dialog: 1, show_confirm: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, default: nil
  attr :request, :any, required: true, doc: "a %Notifications.PermissionRequest{}"
  attr :on_approve, :string, default: "approve"
  attr :on_deny, :string, default: "deny"
  attr :target, :any, default: nil

  def permission_request(assigns) do
    # Scoped to the caller's own `@id`, not `request.id` alone — the same
    # request can be on screen twice at once (the dropdown and an agent's own
    # conversation both render from `Layouts.app/1`), and a confirm dialog
    # keyed only on the request would collide between them.
    confirm_id = "#{assigns.id}-confirm-deny"
    assigns = assign(assigns, :confirm_id, confirm_id)

    ~H"""
    <div
      id={@id}
      data-test="permission-request"
      data-status={@request.status}
      class="card bg-base-200"
    >
      <div class="card-body">
        <h2 class="card-title text-lg">
          <.icon name="hero-shield-check" class="size-5 text-primary" />
          Claude Code permission request
        </h2>

        <div class="mt-2 space-y-3">
          <div>
            <span class="text-sm font-semibold opacity-70">Tool</span>
            <p class="text-lg font-mono">{@request.tool_name}</p>
          </div>

          <div>
            <span class="text-sm font-semibold opacity-70">Details</span>
            <pre class="bg-base-300 rounded-lg p-3 text-sm overflow-x-auto mt-1"><code>{format_input(@request.tool_name, @request.tool_input)}</code></pre>
          </div>

          <div class="text-xs opacity-50">
            Requested <.local_time id={"#{@id}-time"} at={@request.inserted_at} />
          </div>
        </div>

        <div :if={@request.status == "pending"} class="card-actions justify-end mt-4 gap-3">
          <button
            type="button"
            phx-click={show_confirm(@confirm_id)}
            data-test="deny-permission"
            class="btn btn-error"
          >
            Deny
          </button>
          <button
            type="button"
            phx-click={@on_approve}
            phx-value-id={@request.id}
            phx-target={@target}
            data-test="approve-permission"
            class="btn btn-success"
          >
            Approve
          </button>
          <.confirm_dialog
            id={@confirm_id}
            title="Deny this request?"
            confirm_label="Deny"
            on_confirm={deny_js(@on_deny, @request.id, @target)}
          />
        </div>

        <div :if={@request.status != "pending"} data-test="permission-resolved" class="mt-4">
          <span class={["badge", status_badge_class(@request.status)]}>{@request.status}</span>
        </div>
      </div>
    </div>
    """
  end

  # `target: nil` would encode a literal null into the JS op rather than
  # omitting the key the way a `nil` HTML attribute does — the two-clause split
  # keeps a plain page's deny (no LiveComponent in the way) from sending a
  # target the client has to special-case.
  defp deny_js(event, id, nil), do: JS.push(event, value: %{"id" => id})
  defp deny_js(event, id, target), do: JS.push(event, value: %{"id" => id}, target: target)

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
