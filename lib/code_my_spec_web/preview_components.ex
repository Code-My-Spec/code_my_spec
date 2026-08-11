defmodule CodeMySpecWeb.PreviewComponents do
  @moduledoc """
  The preview pane: handed an address and a state, renders the right thing.

  Its whole input is `src` plus `:absent | :starting | :running | :down`, and
  that is deliberate — it means the pane is provable by handing it values, with
  no container, no proxy and no DNS behind it. It decides nothing about where
  the app is or whether it is up; story 886 computes those and passes them in.

  An iframe rather than rendering the target in-page. The alternative fails on
  things that cannot be fixed without forking: the target's `push_patch` calls
  `history.pushState` on `window` and would rewrite the host's address bar,
  `window.liveSocket` is a single global, and the generated app's Tailwind
  preflight would flatten host styles in a shared cascade. The isolation this
  promises — address bar untouched, styling contained — is what a separate
  browsing context gives for free.

  Four states, four screens, and the distinctions matter more than the copy:

  - `:absent` promises nothing, because nothing was asked for. No pane at all.
  - `:starting` promises the app is coming.
  - `:down` says a thing that existed has stopped. Conflating it with
    `:starting` is how a broken app reads as a slow one.
  - `:running` frames the app.
  - `:broken` — up and answering badly. `Workspaces.state/1` reports this and
    885 does not name it, but rendering nothing for a real state would show a
    blank pane for an app that is running and erroring, which is the one
    outcome the pane exists to prevent. Kept distinct from `:down` for the same
    reason `:down` is kept distinct from `:starting`: one is ours to fix and
    the other is the app he just had built.

  `:running` with no `src` is refused rather than framed. An iframe pointed at
  an empty address renders a blank rectangle indistinguishable from an app that
  rendered nothing, so the failure would land on Sam as "my app is broken" when
  the truth is that we do not know where it is.
  """

  use Phoenix.Component

  @widths %{
    "phone" => "w-[390px]",
    "tablet" => "w-[820px]",
    "full" => "w-full"
  }

  attr :src, :string, default: nil
  attr :state, :atom, required: true
  attr :viewport, :string, default: "full"
  attr :title, :string, default: "Your app"

  @doc """
  The pane.

  Narrowing sets the frame's width so the target's own media queries fire.
  Nothing is scaled: a transform would shrink a desktop render, look
  approximately right, and hide the exact breakpoint bug the narrow view was
  opened to find.
  """
  def pane(assigns) do
    assigns = assign(assigns, :width_class, Map.get(@widths, assigns.viewport, "w-full"))

    ~H"""
    <div
      :if={@state != :absent}
      data-test="preview-pane"
      data-viewport={@viewport}
      data-state={@state}
    >
      <div :if={@state == :starting} data-test="preview-starting" class="flex items-center gap-3 p-6">
        <span class="loading loading-spinner loading-sm text-primary"></span>
        <span class="text-sm">Starting your app…</span>
      </div>

      <div :if={@state == :down} data-test="preview-down" class="p-6">
        <span class="text-sm font-medium text-error">Your app is down.</span>
        <p class="text-sm opacity-70">It is not running right now — nothing is being served.</p>
      </div>

      <div :if={@state == :broken} data-test="preview-broken" class="p-6">
        <span class="text-sm font-medium text-error">It is up, but your app is erroring.</span>
        <p class="text-sm opacity-70">The container is serving; the app is answering badly.</p>
      </div>

      <div :if={@state == :running and is_nil(@src)} data-test="preview-unavailable" class="p-6">
        <span class="text-sm font-medium">The preview is unavailable.</span>
        <p class="text-sm opacity-70">
          Your app is running, but we do not have an address for it yet.
        </p>
      </div>

      <iframe
        :if={@state == :running and not is_nil(@src)}
        src={@src}
        title={@title}
        data-test="preview-frame"
        class={["border border-base-300 rounded h-[640px]", @width_class]}
      >
      </iframe>
    </div>
    """
  end
end
