defmodule CodeMySpecWeb.MarketingComponents do
  @moduledoc """
  Function components shared across the marketing pages.

  Standard daisyUI markup only — these render themeable components (badges,
  cards, `mockup-code`) so the whole marketing surface stays on one switchable
  theme. Single source of truth for the section eyebrow and the install card.

  Auto-imported via `CodeMySpecWeb.html_helpers/0`.
  """

  use Phoenix.Component

  @doc """
  Section eyebrow — the small uppercase label that prefaces a section heading.

  ## Examples

      <.eyebrow idx="02" name="the_loop" />
      <.eyebrow idx="05" name="pricing" align="center" />
  """
  attr :idx, :string, default: nil, doc: "optional small index shown before the label"
  attr :name, :string, required: true, doc: "label text; underscores render as spaces"
  attr :align, :string, default: "left", values: ~w(left center)

  def eyebrow(assigns) do
    assigns = assign(assigns, :label, String.replace(assigns.name, "_", " "))

    ~H"""
    <p class={[
      "flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.18em] text-primary",
      @align == "center" && "justify-center"
    ]}>
      <span :if={@idx} class="opacity-50 tabular-nums">{@idx}</span>
      <span>{@label}</span>
    </p>
    """
  end

  @doc """
  Install card — the two `/plugin` commands with a copy button.

  Rendered with daisyUI `card` + `mockup-code`. The copy button ships its data
  via `data-copy`; the delegated click handler lives in `app.js` on
  `.copy-btn[data-copy]`, and the GA4 hooks (`data-event-*`) are preserved.

  ## Examples

      <.install_card harness="codemyspec" brief_url={~p"/products/code-my-spec"} />
  """
  attr :harness, :string, required: true, values: ~w(codemyspec marketmyspec)

  attr :accent, :string,
    default: "red",
    values: ~w(red bdd),
    doc: "retained for call-site compatibility; styling is theme-driven now"

  attr :brief_url, :string, default: nil
  attr :brief_label, :string, default: nil

  attr :footer_label, :string,
    default: nil,
    doc: "small left-side label in the footer (e.g. \"claude code · v1.0\")"

  attr :location, :string,
    default: "unknown",
    doc: "GA4 event_location dimension for install_command_copy"

  def install_card(assigns) do
    assigns =
      assign(assigns, :commands, [
        "/plugin marketplace add Code-My-Spec/plugins",
        "/plugin install #{assigns.harness}@codemyspec"
      ])

    ~H"""
    <div class="card bg-base-200 border border-base-300 shadow-sm">
      <div class="card-body gap-3 p-5">
        <div class="flex items-center justify-between">
          <span class="badge badge-primary badge-sm font-mono">/{@harness}</span>
          <button
            class="copy-btn btn btn-xs btn-outline btn-primary"
            data-copy={Enum.join(@commands, "\n")}
            data-event-name="install_command_copy"
            data-event-harness={@harness}
            data-event-location={@location}
          >
            Copy
          </button>
        </div>
        <div class="mockup-code text-sm w-full">
          <pre :for={cmd <- @commands} data-prefix="$"><code>{cmd}</code></pre>
        </div>
        <div
          :if={@brief_url || @footer_label}
          class="flex justify-between items-center text-xs text-base-content/60 pt-1"
        >
          <span :if={@footer_label}>{@footer_label}</span>
          <a :if={@brief_url} href={@brief_url} class="link link-primary ml-auto">
            {@brief_label || "Read the brief →"}
          </a>
        </div>
      </div>
    </div>
    """
  end
end
