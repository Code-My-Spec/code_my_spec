defmodule CodeMySpecWeb.MarketingComponents do
  @moduledoc """
  Function components shared across the marketing pages.

  Standard daisyUI markup only — these render themeable components (badges,
  cards, `mockup-code`) so the whole marketing surface stays on one switchable
  theme. Single source of truth for the section eyebrow and the install card.

  Auto-imported via `CodeMySpecWeb.html_helpers/0`.
  """

  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: CodeMySpecWeb.Endpoint, router: CodeMySpecWeb.Router

  import CodeMySpecWeb.CoreComponents, only: [icon: 1]

  alias CodeMySpecWeb.ExternalLinks

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

      <.install_card harness="codemyspec" brief_url={~p"/developers"} />
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
    <div class="card bg-base-200 border border-base-300 shadow-sm min-w-0">
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
        <div class="mockup-code text-sm w-full min-w-0">
          <pre :for={cmd <- @commands} data-prefix="$" class="whitespace-pre-wrap break-all"><code>{cmd}</code></pre>
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

  @doc """
  Pricing tiers — the single source of truth for the three plans, reused by
  the homepage teaser and the `/pricing` page so their CTAs never drift.

  Build → `/install` (free), Operate & Grow → `/users/register` (paid
  self-serve), Built with you → John's booking (done-with-you).
  """
  attr :class, :string, default: nil, doc: "extra classes on the grid wrapper"

  def pricing_tiers(assigns) do
    ~H"""
    <div class={["grid md:grid-cols-3 gap-5", @class]}>
      <div class="card bg-base-100 border-2 border-primary shadow-sm">
        <div class="card-body">
          <span class="text-xs font-semibold uppercase tracking-[0.15em] text-base-content/60">
            Build
          </span>
          <div class="text-4xl font-bold mt-1">
            $0 <span class="text-base font-normal text-base-content/50">/ forever</span>
          </div>
          <p class="text-base-content/70">
            The full harness — build the software, and market it before it exists.
          </p>
          <ul class="mt-3 space-y-2 text-sm">
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              Build real software with the model
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              Content engine: your site and blog, live before the app
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              Bring your own AI keys, no markup
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              Yours to keep — no lock-in
            </li>
          </ul>
          <div class="card-actions mt-4">
            <.link href={~p"/install"} class="btn btn-primary btn-block">Start free</.link>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <span class="text-xs font-semibold uppercase tracking-[0.15em] text-base-content/60">
            Operate &amp; Grow
          </span>
          <div class="text-4xl font-bold mt-1">
            $100 <span class="text-base font-normal text-base-content/50">/ month per user</span>
          </div>
          <p class="text-base-content/70">Everything after launch, in one place.</p>
          <ul class="mt-3 space-y-2 text-sm">
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-secondary shrink-0 mt-0.5" />
              Email on your own domain
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-secondary shrink-0 mt-0.5" />
              Live chat + one shared inbox
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-secondary shrink-0 mt-0.5" />
              Content publishing + Google Ads
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-secondary shrink-0 mt-0.5" />
              See who's converting
            </li>
          </ul>
          <div class="card-actions mt-4">
            <.link href={~p"/users/register"} class="btn btn-outline btn-block">Get started</.link>
          </div>
        </div>
      </div>

      <div class="card bg-base-100 border border-base-300 shadow-sm">
        <div class="card-body">
          <span class="text-xs font-semibold uppercase tracking-[0.15em] text-base-content/60">
            Built with you
          </span>
          <div class="text-4xl font-bold mt-1">
            $500 <span class="text-base font-normal text-base-content/50">minimum · quoted</span>
          </div>
          <p class="text-base-content/70">
            John runs the harness on your project. You get working software — and everything on the left.
          </p>
          <ul class="mt-3 space-y-2 text-sm">
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-accent shrink-0 mt-0.5" />
              Scoped and quoted after a real conversation
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-accent shrink-0 mt-0.5" />
              Built the same way — specs, tests, verification
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-accent shrink-0 mt-0.5" />
              You own everything when it ships
            </li>
          </ul>
          <div class="card-actions mt-4">
            <a href={ExternalLinks.cal_john()} class="btn btn-outline btn-block">Talk to John</a>
          </div>
        </div>
      </div>
    </div>
    <p class="text-sm text-base-content/50 mt-4">
      Built with you is a conversation, not a checkout. Bring what you're trying to run and John will quote it.
    </p>
    """
  end
end
