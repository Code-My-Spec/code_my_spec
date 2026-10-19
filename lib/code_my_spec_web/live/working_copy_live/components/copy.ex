defmodule CodeMySpecWeb.WorkingCopyLive.Components.Copy do
  @moduledoc """
  What a working copy is doing, from its `Rows` row: its app, its preview, its
  machine, whether anything serves it, and whether its checkout is still there.

  The pieces compose: the cockpit's copy modal and `WorkingCopyLive.Show` use
  `facts/1` bare; `WorkingCopyLive.Index` gives it a title and actions.
  """
  use CodeMySpecWeb, :html

  attr :row, :map, required: true
  attr :class, :any, default: nil
  slot :title
  slot :actions

  def facts(assigns) do
    ~H"""
    <div
      data-test="working-copy"
      data-working-copy-id={@row.harness.id}
      data-root={@row.harness.root}
      class={["space-y-1.5", @class]}
    >
      {render_slot(@title)}
      <%!-- Where this copy's preview answers. Only the copy that has one shows
      one, which is the whole of "a worktree does not claim to be where the
      preview runs". --%>
      <a
        :if={@row.harness.preview_url}
        data-test="working-copy-preview"
        href={@row.harness.preview_url}
        target="_blank"
        rel="noopener"
        class="block truncate text-xs link link-hover opacity-60"
      >
        {URI.parse(@row.harness.preview_url).host}
      </a>

      <%!-- Story 1108: this copy's own app, separate from `preview_url` —
      every copy runs one. Without it a broken app read as a silent hang. --%>
      <div class="flex flex-wrap items-center gap-1.5">
        <span
          :if={@row.harness.app_status}
          data-test="working-copy-app-status"
          data-app-status={@row.harness.app_status}
          class={["badge badge-sm", app_status_badge_class(@row.harness.app_status)]}
        >
          <.icon name={app_status_icon(@row.harness.app_status)} class="size-3" />
          app {@row.harness.app_status}
          <span :if={@row.harness.app_commit} data-test="working-copy-app-commit">
            &nbsp;{String.slice(@row.harness.app_commit, 0, 8)}
          </span>
        </span>

        <%!-- Whether anything serves this checkout, which liveness does not
        answer: a worktree created for an agent has nobody to open a session
        in it, and once sat unserved for an hour with an agent assigned. --%>
        <span :if={not @row.served} data-test="copy-not-ready" class="badge badge-ghost badge-sm">
          <.icon name="hero-signal-slash" class="size-3" /> Not being served
        </span>
        <span :if={@row.served} data-test="copy-ready" class="sr-only">served</span>

        <span :if={@row.missing} data-test="path-missing" class="badge badge-warning badge-sm">
          <.icon name="hero-exclamation-triangle" class="size-3" /> Checkout gone
          <span :if={@row.missing.since} data-test="path-missing-since">
            &nbsp;{@row.missing.since}
          </span>
        </span>
      </div>

      <div class="truncate text-xs opacity-60">
        <span :if={@row.device} data-test="working-copy-device" data-device-id={@row.device.id}>
          on {@row.device_name}
        </span>
        <span :if={is_nil(@row.device)} data-test="working-copy-no-device">
          no machine — never reported one, or it may be orphaned
        </span>
      </div>

      <p :if={@row.missing} data-test="path-missing-basis" class="text-xs text-warning/80">
        Its machine reports nothing at this path. Nothing has been removed —
        offboard it when you are sure it is not coming back.
      </p>

      <p
        :if={@row.other_copies_at_root && @row.other_copies_at_root > 0}
        data-test="other-copies-at-root"
        class="text-xs opacity-60"
      >
        +{@row.other_copies_at_root} other {if @row.other_copies_at_root == 1,
          do: "checkout",
          else: "checkouts"} at this same path
      </p>

      <div data-test="liveness" class="text-sm">
        {@row.liveness.label}
        <span :if={@row.liveness.since} data-test="liveness-since" class="opacity-70">
          {@row.liveness.since}
        </span>
        <div data-test="liveness-basis" class="text-xs opacity-60">{@row.liveness.basis}</div>
      </div>

      <p :if={@row.last_message} class="text-xs opacity-60">
        <span data-test="last-message">last message {@row.last_message}</span>
      </p>

      <div :if={@actions != []} class="flex items-center gap-2 pt-1.5">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Whether this copy's app is up and where to open it, as one mark with a
  tooltip: green and linked to the preview when it is shared on a tunnel,
  linked to the local address when it runs only on its own machine, grey when
  nothing is running.

  Serving is either signal: the main copy reports its preview's health
  (`preview_status`), every other copy its own app's (`app_status`).
  """
  attr :harness, :map, required: true
  attr :class, :any, default: "tooltip-left"

  def preview_marker(assigns) do
    {state, href, tip} = preview_state(assigns.harness)
    assigns = assign(assigns, state: state, href: href, tip: tip)

    ~H"""
    <a
      :if={@href}
      href={@href}
      target="_blank"
      rel="noopener"
      data-test="copy-preview-marker"
      data-state={@state}
      data-tip={@tip}
      aria-label={@tip}
      class={["tooltip flex shrink-0", preview_color(@state), @class]}
    >
      <.icon name={preview_icon(@state)} class="size-3.5" />
    </a>
    <span
      :if={!@href}
      data-test="copy-preview-marker"
      data-state={@state}
      data-tip={@tip}
      aria-label={@tip}
      class={["tooltip flex shrink-0", preview_color(@state), @class]}
    >
      <.icon name={preview_icon(@state)} class="size-3.5" />
    </span>
    """
  end

  defp preview_state(harness) do
    serving? = harness.app_status == "serving" or harness.preview_status == "serving"
    erroring? = harness.app_status == "erroring" or harness.preview_status == "erroring"
    url = harness.preview_url || harness.app_url

    cond do
      serving? and harness.preview_url ->
        {:shared, harness.preview_url, "Serving at #{host(harness.preview_url)}"}

      serving? and harness.app_url ->
        {:local, harness.app_url,
         "Running locally at #{host(harness.app_url)} — not on a tunnel, so only its own machine can open it"}

      erroring? and url ->
        {:erroring, url, "Answering with errors at #{host(url)}"}

      harness.app_status == "starting" ->
        {:starting, nil, "Starting — the first install and compile are still running"}

      true ->
        {:down, nil, "No app running on this copy"}
    end
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host, port: port} when port in [80, 443, nil] -> host
      %URI{host: host, port: port} -> "#{host}:#{port}"
    end
  end

  defp preview_color(:shared), do: "text-success"
  defp preview_color(:local), do: "text-info"
  defp preview_color(:erroring), do: "text-warning"
  defp preview_color(:starting), do: "text-info opacity-70"
  defp preview_color(:down), do: "opacity-40"

  defp preview_icon(:shared), do: "hero-globe-alt"
  defp preview_icon(:local), do: "hero-computer-desktop"
  defp preview_icon(:erroring), do: "hero-exclamation-triangle"
  defp preview_icon(:starting), do: "hero-arrow-path"
  defp preview_icon(:down), do: "hero-signal-slash"

  @doc """
  Offboarding, and only when asked: removes the copy's row and what was
  derived from it, never the checkout on disk. Nothing does it on a timer —
  story 892's automatic reclaim trusted a signal that went stale while agents
  worked, and came within one sync of deleting two live agents' files.

  Pushes `"offboard"` with the copy's id; the page that renders it handles it.
  """
  attr :row, :map, required: true

  def offboard(assigns) do
    ~H"""
    <button
      type="button"
      data-test="offboard-working-copy"
      data-working-copy-id={@row.harness.id}
      class="btn btn-sm btn-ghost text-error"
      phx-click={show_confirm("offboard-#{@row.harness.id}")}
    >
      <.icon name="hero-trash" /> Offboard
    </button>
    <.confirm_dialog
      id={"offboard-#{@row.harness.id}"}
      title="Offboard this working copy?"
      message={
        "Removes #{@row.label} and everything derived from it — its files, " <>
          "its problems, and any component left with nothing pointing at it. " <>
          "The checkout on disk is not touched."
      }
      confirm_label="Offboard"
      on_confirm={JS.push("offboard", value: %{id: @row.harness.id})}
    />
    """
  end

  @doc """
  A copy at a glance, over whatever page is open: its facts and the way to its
  show and status pages. Pushes `on_close` to close.
  """
  attr :row, :map, required: true
  attr :project_id, :string, required: true
  attr :on_close, :string, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="copy-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
    >
      <div class="modal-box space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <h2 class="flex items-center gap-1.5 pr-8 text-lg font-semibold">
          <.icon :if={@row.harness.main} name="hero-star-solid" class="size-4 text-primary" />
          <span class="truncate">{@row.heading}</span>
        </h2>
        <.facts row={@row} />
        <div class="flex justify-end gap-2">
          <.link
            navigate={~p"/app/projects/#{@project_id}/working-copies/#{@row.harness.id}/status"}
            data-test="copy-modal-status"
            class="btn btn-sm btn-ghost"
          >
            Status
          </.link>
          <.link
            navigate={~p"/app/projects/#{@project_id}/working-copies/#{@row.harness.id}"}
            data-test="copy-modal-show"
            class="btn btn-sm"
          >
            Open <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button type="button" class="modal-backdrop" phx-click={@on_close} aria-label="Close"></button>
    </div>
    """
  end

  @doc """
  What offboarding removed, in counts, for the flash: "Offboarded" alone
  leaves the reader wondering whether it did anything. An agent that would
  not stop is said out loud — the copy is gone from here and a process may
  still be running on a machine the server could not reach.
  """
  def offboarded(row, %{files: files, problems: problems, components: components} = counts) do
    "Offboarded #{row.label} — #{count(files, "file")}, #{count(problems, "problem")} " <>
      "and #{count(components, "orphaned component")} removed." <> agents(counts)
  end

  defp agents(%{agents_stopped: 0, agents_left_running: []}), do: ""

  defp agents(%{agents_stopped: stopped, agents_left_running: []}),
    do: " #{count(stopped, "agent")} stopped."

  defp agents(%{agents_stopped: stopped, agents_left_running: left}) do
    " #{count(stopped, "agent")} stopped, and #{count(length(left), "agent")} could not be " <>
      "reached — #{Enum.join(left, ", ")} may still be running on its machine."
  end

  defp agents(_counts), do: ""

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"

  # `WorkingCopy.app_status` follows `preview_status`'s three states
  # (`serving` | `erroring` | `down`), plus `starting` — a first start's cold
  # install/compile still running in the background.
  defp app_status_badge_class("serving"), do: "badge-success"
  defp app_status_badge_class("erroring"), do: "badge-warning"
  defp app_status_badge_class("down"), do: "badge-error"
  defp app_status_badge_class("starting"), do: "badge-info"
  defp app_status_badge_class(_other), do: "badge-ghost"

  defp app_status_icon("serving"), do: "hero-check-circle"
  defp app_status_icon("erroring"), do: "hero-exclamation-triangle"
  defp app_status_icon("down"), do: "hero-signal-slash"
  defp app_status_icon("starting"), do: "hero-arrow-path"
  defp app_status_icon(_other), do: "hero-question-mark-circle"
end
