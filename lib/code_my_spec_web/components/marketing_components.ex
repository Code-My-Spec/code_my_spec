defmodule CodeMySpecWeb.MarketingComponents do
  @moduledoc """
  Function components for the marketing zones (brand + product pages).

  These components own the brand-system markup that was previously copy-pasted
  across `home.html.heex`, `code_my_spec.html.heex`, `market_my_spec.html.heex`,
  and `methodology.ex`. Single source of truth for the eyebrow header, the
  /codemyspec install card, and any future shared marketing chrome.

  Auto-imported via `CodeMySpecWeb.html_helpers/0`.
  """

  use Phoenix.Component

  @doc """
  Section eyebrow — the index-slash-name label that prefaces every marketing
  section heading. Renders the brand pattern:

      <p class="eyebrow"><span class="idx">02</span><span>// the_loop</span></p>

  Eyebrow styling is defined in `app.css` under `.brand-zone .eyebrow` /
  `.product-page-zone .eyebrow`, so this component only renders markup —
  it does not work outside a marketing-zone wrapper.

  ## Examples

      <.eyebrow idx="02" name="the_loop" />
      <.eyebrow idx="05" name="pricing" align="center" />
  """
  attr :idx, :string, required: true, doc: "two-digit index, e.g. \"02\""
  attr :name, :string, required: true, doc: "snake_case name shown after the //"
  attr :align, :string, default: "left", values: ~w(left center)

  def eyebrow(assigns) do
    ~H"""
    <p class={["eyebrow", @align == "center" && "justify-center"]}>
      <span class="idx">{@idx}</span><span>// {@name}</span>
    </p>
    """
  end

  @doc """
  /codemyspec or /marketmyspec install card.

  Renders the chamfered terminal panel with the harness label, copy button,
  the two `/plugin` commands, and an optional footer link. The copy button
  ships its data via `data-copy`; the click handler lives in `app.js` as a
  delegated listener on `.copy-btn[data-copy]`.

  Class strings are looked up via `accent_classes/1` (literal strings only —
  Tailwind's content scanner can't see runtime-interpolated class names).

  ## Examples

      <.install_card harness="codemyspec" brief_url={~p"/products/code-my-spec"} />
      <.install_card harness="marketmyspec" accent="bdd" brief_url={~p"/products/market-my-spec"} brief_label="Read the marketing brief →" />
  """
  attr :harness, :string, required: true, values: ~w(codemyspec marketmyspec)

  attr :accent, :string,
    default: "red",
    values: ~w(red bdd),
    doc: "color theme: \"red\" (primary) or \"bdd\" (cms-agent-bdd)"

  attr :brief_url, :string, default: nil
  attr :brief_label, :string, default: nil

  attr :footer_label, :string,
    default: nil,
    doc: "small left-side label in the footer (e.g. \"claude code · v1.0\")"

  def install_card(assigns) do
    assigns =
      assigns
      |> assign(:commands, [
        "/plugin marketplace add Code-My-Spec/plugins",
        "/plugin install #{assigns.harness}@codemyspec"
      ])
      |> assign(:c, accent_classes(assigns.accent))

    ~H"""
    <div class={[
      "border-[1.5px] bg-gradient-to-b from-base-100 to-base-200 chamfer-lg overflow-hidden",
      @c.border
    ]}>
      <div class={["flex items-center justify-between px-4 py-3.5 border-b", @c.border_30, @c.bg_grad]}>
        <span class={[
          "font-mono text-[11px] uppercase tracking-[0.22em] font-bold flex items-center gap-2.5",
          @c.text
        ]}>
          <span class={["w-1.5 h-1.5 inline-block", @c.bg, @c.glow]}></span> /{@harness}
        </span>
        <button
          class={[
            "copy-btn font-mono text-[10px] uppercase tracking-[0.2em] border px-2.5 py-1.5 transition hover:text-base-100",
            @c.text,
            @c.border,
            @c.hover_bg
          ]}
          data-copy={Enum.join(@commands, "\n")}
        >
          [ copy ]
        </button>
      </div>
      <div class="px-4 py-4 font-mono text-sm">
        <div :for={cmd <- @commands} class="flex gap-2.5 py-1">
          <span class={["font-bold select-none", @c.text]}>▸</span>
          <span class="break-all">{cmd}</span>
        </div>
      </div>
      <div
        :if={@brief_url || @footer_label}
        class={[
          "flex justify-between items-center px-4 py-3.5 border-t font-mono text-[11px] uppercase tracking-[0.14em] text-base-content/70",
          @c.border_30
        ]}
      >
        <span :if={@footer_label}>{@footer_label}</span>
        <a
          :if={@brief_url}
          href={@brief_url}
          class={["border-b pb-0.5 hover:text-base-content transition ml-auto", @c.text, @c.border]}
        >
          {@brief_label || "Read the brief →"}
        </a>
      </div>
    </div>
    """
  end

  # Literal-string class maps so Tailwind's content scanner sees every class.
  # Add a new key here to support a new accent.
  defp accent_classes("red") do
    %{
      text: "text-primary",
      bg: "bg-primary",
      border: "border-primary",
      border_30: "border-primary/30",
      hover_bg: "hover:bg-primary",
      bg_grad: "bg-gradient-to-r from-primary/15 to-transparent",
      glow: "[box-shadow:0_0_6px_var(--color-cms-red)]"
    }
  end

  defp accent_classes("bdd") do
    %{
      text: "text-cms-agent-bdd",
      bg: "bg-cms-agent-bdd",
      border: "border-cms-agent-bdd",
      border_30: "border-cms-agent-bdd/30",
      hover_bg: "hover:bg-cms-agent-bdd",
      bg_grad: "bg-gradient-to-r from-cms-agent-bdd/15 to-transparent",
      glow: ""
    }
  end
end
