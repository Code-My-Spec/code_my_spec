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
        <.preview_marker harness={@row.harness} size={:normal} class="tooltip-right" />

        <.harness_marker row={@row} size={:normal} class="tooltip-right" />

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
  Whether this copy's app is up and where to open it — the one reading of
  that, wherever it is shown. Green and linked to the preview when it is shared
  on a tunnel, linked to the local address when it runs only on its own
  machine, grey when nothing is running.

  `:small` is the mark alone, its reading in a tooltip. `:normal` adds the
  label and the commit the app launched from, and says nothing for a copy
  never checked: nil is "nothing to say", not evidence of being down.

  Serving is either signal: the main copy reports its preview's health
  (`preview_status`), every other copy its own app's (`app_status`).
  """
  attr :harness, :map, required: true
  attr :size, :atom, default: :small, values: [:small, :normal]
  attr :class, :any, default: "tooltip-left"

  def preview_marker(assigns) do
    {state, href, tip} = preview_state(assigns.harness)
    assigns = assign(assigns, state: state, href: href, tip: tip)

    ~H"""
    <.dynamic_tag
      :if={@size == :small or @state != :unchecked}
      tag_name={if @href, do: "a", else: "span"}
      {link_attrs(@href)}
      data-test={if @size == :small, do: "copy-preview-marker", else: "working-copy-app-status"}
      data-state={@state}
      data-app-status={@harness.app_status || @harness.preview_status}
      data-app-instance-id={@harness.app_instance_id}
      data-tip={@tip}
      aria-label={@tip}
      class={[
        "tooltip flex shrink-0 items-center gap-1",
        @size == :normal && "w-fit text-xs",
        preview_color(@state),
        @class
      ]}
    >
      <.icon name={preview_icon(@state)} class="size-3.5" />
      <span :if={@size == :normal}>{preview_label(@state)}</span>
      <span
        :if={@size == :normal and @harness.app_commit}
        data-test="working-copy-app-commit"
        class="font-mono opacity-70"
      >
        {String.slice(@harness.app_commit, 0, 8)}
      </span>
    </.dynamic_tag>
    """
  end

  @doc """
  How many problems this copy holds, coloured by the worst of them: red with
  any error, amber with warnings, grey with only advisory findings, nothing at
  zero. A count rather than a shape — at this size a proportion cannot be read
  — with the split by source and severity in the tooltip. A link with `href`;
  otherwise a button carrying whatever `phx-click` the page gives it.

  `:small` is the compact number alone (`7`, `214`, `1.2k`); `:normal` says
  "214 problems".
  """
  attr :tally, :list, required: true, doc: "`[{source, severity, count}]` for this copy"
  attr :href, :string, default: nil
  attr :rest, :global
  attr :size, :atom, default: :small, values: [:small, :normal]
  attr :class, :any, default: "tooltip-left"

  def problems_marker(assigns) do
    total = assigns.tally |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    assigns = assign(assigns, total: total, worst: worst(assigns.tally))

    ~H"""
    <.dynamic_tag
      :if={@total > 0}
      tag_name={if @href, do: "a", else: "button"}
      {if @href, do: [href: @href], else: [type: "button"]}
      data-test="copy-problems-marker"
      data-total={@total}
      data-worst={@worst}
      data-tip={problems_tip(@tally, @total)}
      aria-label={problems_tip(@tally, @total)}
      class={[
        "tooltip shrink-0 cursor-pointer font-mono tabular-nums",
        @size == :small && "text-[11px]",
        @size == :normal && "text-xs",
        worst_color(@worst),
        @class
      ]}
      {@rest}
    >
      {compact(@total)}{if @size == :normal,
        do: " #{if @total == 1, do: "problem", else: "problems"}"}
    </.dynamic_tag>
    """
  end

  defp worst(tally) do
    severities = MapSet.new(tally, &elem(&1, 1))

    cond do
      MapSet.member?(severities, :error) -> :error
      MapSet.member?(severities, :warning) -> :warning
      true -> :info
    end
  end

  defp worst_color(:error), do: "text-error"
  defp worst_color(:warning), do: "text-warning"
  defp worst_color(:info), do: "opacity-50"

  # "214 problems — exunit 5 error · credo 4 error · credo 205 info", worst first.
  defp problems_tip(tally, total) do
    split =
      tally
      |> Enum.sort_by(fn {source, severity, count} ->
        {severity_rank(severity), -count, source}
      end)
      |> Enum.map_join(" · ", fn {source, severity, count} ->
        "#{source} #{count} #{severity || "unrated"}"
      end)

    "#{total} #{if total == 1, do: "problem", else: "problems"} — #{split}"
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(_other), do: 2

  @doc "A count in at most four characters: `999`, `1.2k`, `12k`, `1.2M`."
  def compact(n) when n < 1_000, do: Integer.to_string(n)
  def compact(n) when n < 10_000, do: one_decimal(n / 1_000) <> "k"
  def compact(n) when n < 1_000_000, do: "#{div(n, 1_000)}k"
  def compact(n) when n < 10_000_000, do: one_decimal(n / 1_000_000) <> "M"
  def compact(n), do: "#{div(n, 1_000_000)}M"

  # 1.0 reads as 1: the decimal is only there when it says something.
  defp one_decimal(x) do
    tenths = trunc(x * 10)

    if rem(tenths, 10) == 0,
      do: "#{div(tenths, 10)}",
      else: "#{div(tenths, 10)}.#{rem(tenths, 10)}"
  end

  @doc """
  Whether a harness holds this checkout — the process on its machine that
  agents run through. Not the app: a copy can serve its app with no harness,
  and then nothing can start its agents. A worktree created for an agent has
  nobody to open a session in it, and once sat unattached for an hour with an
  agent assigned.

  `:small` is the mark alone, faint when attached and amber when not.
  `:normal` says so only when it is not attached.
  """
  attr :row, :map, required: true
  attr :size, :atom, default: :small, values: [:small, :normal]
  attr :class, :any, default: "tooltip-left"

  def harness_marker(assigns) do
    assigns = assign(assigns, :tip, harness_tip(assigns.row))

    ~H"""
    <span
      :if={@size == :small}
      data-test="copy-harness-marker"
      data-state={if @row.served, do: "attached", else: "unattached"}
      data-tip={@tip}
      aria-label={@tip}
      class={[
        "tooltip flex shrink-0",
        if(@row.served, do: "opacity-40", else: "text-warning"),
        @class
      ]}
    >
      <.icon name={if @row.served, do: "hero-link", else: "hero-link-slash"} class="size-3.5" />
    </span>
    <span
      :if={@size == :normal and not @row.served}
      data-test="copy-not-ready"
      data-tip={@tip}
      class={["tooltip badge badge-ghost badge-sm", @class]}
    >
      <.icon name="hero-link-slash" class="size-3" /> No harness attached
    </span>
    <span :if={@size == :normal and @row.served} data-test="copy-ready" class="sr-only">
      served
    </span>
    """
  end

  defp harness_tip(%{served: true, device_name: name}) when is_binary(name),
    do: "Held by the harness on #{name}"

  defp harness_tip(%{served: true}), do: "Held by a harness"

  defp harness_tip(_row),
    do: "No harness on its machine holds this checkout, so its agents cannot run"

  defp link_attrs(nil), do: []
  defp link_attrs(href), do: [href: href, target: "_blank", rel: "noopener"]

  defp preview_state(harness), do: preview_state(health(harness), harness)

  defp preview_state(:serving, %{preview_url: url}) when is_binary(url),
    do: {:shared, url, "Serving at #{host(url)}"}

  defp preview_state(:serving, %{app_url: url}) when is_binary(url),
    do:
      {:local, url,
       "Running locally at #{host(url)} — not on a tunnel, so only its own machine can open it"}

  defp preview_state(:erroring, harness) do
    case harness.preview_url || harness.app_url do
      nil -> {:down, nil, "No app running on this copy"}
      url -> {:erroring, url, "Answering with errors at #{host(url)}"}
    end
  end

  defp preview_state(_health, %{app_status: "starting"}),
    do: {:starting, nil, "Starting — the first install and compile are still running"}

  defp preview_state(_health, %{app_status: nil, preview_status: nil}),
    do: {:unchecked, nil, "Not checked yet"}

  defp preview_state(_health, _harness), do: {:down, nil, "No app running on this copy"}

  defp health(%{app_status: app, preview_status: preview}) do
    cond do
      "serving" in [app, preview] -> :serving
      "erroring" in [app, preview] -> :erroring
      true -> :down
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
  defp preview_color(_down_or_unchecked), do: "opacity-40"

  defp preview_icon(:shared), do: "hero-globe-alt"
  defp preview_icon(:local), do: "hero-computer-desktop"
  defp preview_icon(:erroring), do: "hero-exclamation-triangle"
  defp preview_icon(:starting), do: "hero-arrow-path"
  defp preview_icon(:down), do: "hero-signal-slash"
  defp preview_icon(:unchecked), do: "hero-question-mark-circle"

  defp preview_label(:shared), do: "app serving"
  defp preview_label(:local), do: "app serving locally"
  defp preview_label(:erroring), do: "app erroring"
  defp preview_label(:starting), do: "app starting"
  defp preview_label(:down), do: "app down"

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
end
