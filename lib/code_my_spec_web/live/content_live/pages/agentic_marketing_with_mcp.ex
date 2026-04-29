defmodule CodeMySpecWeb.ContentLive.Pages.AgenticMarketingWithMcp do
  @moduledoc """
  Renders the /blog/agentic-marketing-with-mcp post — the founder-direct
  story of building the marketing harness with Claude Code + MCP servers.

  Static LiveView: copy is loaded at compile time from
  `agentic_marketing_with_mcp_copy.exs`. Mount emits SEO meta and JSON-LD
  (BlogPosting + BreadcrumbList + FAQPage). A colocated `.ReadingProgress`
  hook drives the top progress bar; copy buttons are handled by the shared
  `<.install_card>` component (delegated `.copy-btn[data-copy]` listener in
  app.js).
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @external_resource copy_path = Path.join(__DIR__, "agentic_marketing_with_mcp_copy.exs")

  @copy (case Code.eval_file(copy_path) do
           {copy, _} -> copy
         end)

  @published_at "2026-04-28T00:00:00Z"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div id="agentic-marketing-page" class="product-page-zone hair-grid">
        <div
          id="reading-progress"
          phx-hook=".ReadingProgress"
          phx-update="ignore"
          class="fixed top-0 left-0 h-[2px] bg-primary [box-shadow:0_0_12px_var(--color-cms-red)] z-50 w-0 transition-[width] duration-75 ease-linear"
        >
        </div>

        {hero_section(assigns)}
        {lede_section(assigns)}
        {loop_diagram_section(assigns)}
        {origin_section(assigns)}
        {daily_loop_section(assigns)}
        {stack_section(assigns)}
        {mistakes_section(assigns)}
        {results_section(assigns)}
        {files_section(assigns)}
        {install_section(assigns)}
        {cta_section(assigns)}
        {faq_section(assigns)}
        {sources_section(assigns)}
        {footer_section(assigns)}
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReadingProgress">
        export default {
          mounted() {
            this._tick = () => {
              const h = document.documentElement;
              const max = h.scrollHeight - h.clientHeight;
              const pct = max > 0 ? (h.scrollTop / max) * 100 : 0;
              this.el.style.width = pct + "%";
            };
            document.addEventListener("scroll", this._tick, { passive: true });
            this._tick();
          },
          destroyed() {
            document.removeEventListener("scroll", this._tick);
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    base_url = CodeMySpecWeb.Endpoint.url()
    canonical = "#{base_url}/blog/agentic-marketing-with-mcp"

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "BlogPosting",
          "@id" => canonical,
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => canonical,
          "datePublished" => @published_at,
          "dateModified" => @published_at,
          "author" => %{
            "@type" => "Person",
            "@id" => "#{base_url}/author/john-davenport",
            "name" => "John Davenport",
            "url" => "#{base_url}/author/john-davenport"
          },
          "publisher" => %{
            "@type" => "Organization",
            "@id" => "#{base_url}/#organization",
            "name" => "CodeMySpec",
            "logo" => %{
              "@type" => "ImageObject",
              "url" => "#{base_url}/images/logo-300.png",
              "width" => 300,
              "height" => 300
            }
          },
          "mainEntityOfPage" => %{"@type" => "WebPage", "@id" => canonical},
          "articleSection" => "Methodology",
          "keywords" => Enum.join(@copy.metadata.tags, ", ")
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{"@type" => "ListItem", "position" => 2, "name" => "Blog", "item" => "#{base_url}/blog"},
            %{
              "@type" => "ListItem",
              "position" => 3,
              "name" => "Agentic Marketing with MCP",
              "item" => canonical
            }
          ]
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(@copy.faq.items, fn item ->
              %{
                "@type" => "Question",
                "name" => item.question,
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" => strip_html(item.answer)
                }
              }
            end)
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:page_title, @copy.metadata.meta_title)
     |> assign(:canonical_url, canonical)
     |> assign(:og_image, nil)
     |> assign(:og_type, "article")
     |> assign(:article_published_time, @published_at)
     |> assign(:json_ld, json_ld)}
  end

  # ─── HERO ───
  defp hero_section(assigns) do
    ~H"""
    <section class="border-b border-primary/20 signal-top scanlines relative overflow-hidden">
      <div class="max-w-3xl mx-auto px-6 pt-32 pb-20">
        <div class="font-mono text-[11px] uppercase tracking-[0.22em] text-primary flex items-center gap-3.5 mb-7">
          <span class="text-base-content/40">{@copy.hero.eyebrow_idx}</span>
          <span>{@copy.hero.eyebrow_kind}</span>
          <span class="flex-1 h-px bg-gradient-to-r from-primary to-transparent max-w-[240px]"></span>
        </div>

        <h1 class="font-heading font-bold uppercase text-4xl sm:text-5xl md:text-6xl lg:text-7xl leading-none tracking-[-0.035em] text-base-content">
          <%= for {line, i} <- Enum.with_index(@copy.hero.title_lines) do %>
            <span class={["block", i == @copy.hero.title_accent_index && "text-primary"]}>
              {line}
            </span>
          <% end %>
        </h1>

        <p class="text-lg text-base-content/70 mt-7 max-w-[62ch] leading-relaxed">
          {@copy.hero.deck}
        </p>

        <div class="mt-9 flex flex-wrap gap-x-9 gap-y-5 font-mono text-[11px] uppercase tracking-[0.16em] text-base-content/50">
          <%= for {item, i} <- Enum.with_index(@copy.hero.meta) do %>
            <%= if i > 0 do %>
              <span class="text-primary">/</span>
            <% end %>
            <span>
              <span :if={item.label} class="text-base-content font-medium">{item.label}</span>
              <span :if={item.label && item.suffix}>{" "}</span>
              <span :if={item.suffix}>{item.suffix}</span>
            </span>
          <% end %>
        </div>

        <div class="mt-14 px-7 py-6 border border-primary/20 bg-gradient-to-r from-primary/[0.06] to-transparent chamfer-md">
          <div class="flex items-center gap-2 font-mono text-[10px] uppercase tracking-[0.22em] text-primary mb-2">
            <span class="w-2 h-2 bg-primary [box-shadow:0_0_6px_var(--color-cms-red)]"></span>
            Recursion note
          </div>
          <p class="text-[15px] leading-relaxed m-0">{@copy.hero.recursion_note}</p>
        </div>
      </div>
    </section>
    """
  end

  # ─── LEDE ───
  defp lede_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 pt-14">
        <p class="text-[19px] text-base-content leading-relaxed font-medium">{@copy.lede}</p>
        <%= for p <- @copy.intro_paragraphs do %>
          <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">{Phoenix.HTML.raw(p)}</p>
        <% end %>
      </div>
    </section>
    """
  end

  # ─── LOOP DIAGRAM ───
  defp loop_diagram_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-16">
        <figure
          id="loop"
          class="m-0 border border-primary/20 bg-base-200 chamfer-lg overflow-hidden"
        >
          <figcaption class="flex justify-between items-center px-6 py-3.5 border-b border-base-300 font-mono text-[10px] uppercase tracking-[0.22em] text-base-content/50 bg-primary/[0.03]">
            <span class="text-primary">{@copy.loop_diagram.fig_label}</span>
            <span>{@copy.loop_diagram.fig_caption}</span>
          </figcaption>
          <div class="px-7 py-15 bg-[radial-gradient(ellipse_at_center,rgba(255,56,56,0.08)_0%,transparent_70%)]">
            <svg
              viewBox="0 0 760 360"
              xmlns="http://www.w3.org/2000/svg"
              class="block w-full h-auto max-w-[780px] mx-auto"
              role="img"
              aria-label="The marketing loop: strategy → daily plan → execute → measure → iterate"
            >
              <defs>
                <marker id="ammloop-arr" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto">
                  <path d="M0,0 L10,5 L0,10 z" fill="#ff3838" />
                </marker>
              </defs>
              <g stroke="rgba(255,56,56,0.08)" stroke-width="1">
                <line x1="0" y1="60" x2="760" y2="60" />
                <line x1="0" y1="180" x2="760" y2="180" />
                <line x1="0" y1="300" x2="760" y2="300" />
              </g>
              <g font-family="JetBrains Mono, monospace">
                <g transform="translate(60,140)">
                  <path
                    d="M10,0 L150,0 L150,70 L140,80 L0,80 L0,10 Z"
                    fill="#0a0a0c"
                    stroke="#ff3838"
                    stroke-width="1.5"
                  />
                  <text x="14" y="24" font-family="Space Mono, monospace" font-weight="700" font-size="14" fill="#ff3838">
                    01
                  </text>
                  <text x="14" y="48" font-size="11" font-weight="600" fill="#f5f5f7" letter-spacing="1.2">
                    STRATEGY
                  </text>
                  <text x="14" y="66" font-size="9.5" fill="#8a8a93" letter-spacing="1">
                    /marketing-strategy
                  </text>
                </g>
                <g transform="translate(260,140)">
                  <path
                    d="M10,0 L150,0 L150,70 L140,80 L0,80 L0,10 Z"
                    fill="#0a0a0c"
                    stroke="#ff3838"
                    stroke-width="1.5"
                  />
                  <text x="14" y="24" font-family="Space Mono, monospace" font-weight="700" font-size="14" fill="#ff3838">
                    02
                  </text>
                  <text x="14" y="48" font-size="11" font-weight="600" fill="#f5f5f7" letter-spacing="1.2">
                    DAILY PLAN
                  </text>
                  <text x="14" y="66" font-size="9.5" fill="#8a8a93" letter-spacing="1">
                    /daily-plan
                  </text>
                </g>
                <g transform="translate(460,140)">
                  <path
                    d="M10,0 L150,0 L150,70 L140,80 L0,80 L0,10 Z"
                    fill="#0a0a0c"
                    stroke="#ff3838"
                    stroke-width="1.5"
                  />
                  <text x="14" y="24" font-family="Space Mono, monospace" font-weight="700" font-size="14" fill="#ff3838">
                    03
                  </text>
                  <text x="14" y="48" font-size="11" font-weight="600" fill="#f5f5f7" letter-spacing="1.2">
                    EXECUTE
                  </text>
                  <text x="14" y="66" font-size="9.5" fill="#8a8a93" letter-spacing="1">
                    scan · draft · post
                  </text>
                </g>
                <g transform="translate(580,40)">
                  <path
                    d="M10,0 L130,0 L130,60 L120,70 L0,70 L0,10 Z"
                    fill="#0a0a0c"
                    stroke="#ff3838"
                    stroke-width="1.5"
                  />
                  <text x="14" y="22" font-family="Space Mono, monospace" font-weight="700" font-size="14" fill="#ff3838">
                    04
                  </text>
                  <text x="14" y="42" font-size="11" font-weight="600" fill="#f5f5f7" letter-spacing="1.2">
                    MEASURE
                  </text>
                  <text x="14" y="60" font-size="9.5" fill="#8a8a93" letter-spacing="1">
                    GA4 · GSC
                  </text>
                </g>
                <g transform="translate(580,260)">
                  <path
                    d="M10,0 L130,0 L130,60 L120,70 L0,70 L0,10 Z"
                    fill="#0a0a0c"
                    stroke="#ff3838"
                    stroke-width="1.5"
                  />
                  <text x="14" y="22" font-family="Space Mono, monospace" font-weight="700" font-size="14" fill="#ff3838">
                    05
                  </text>
                  <text x="14" y="42" font-size="11" font-weight="600" fill="#f5f5f7" letter-spacing="1.2">
                    ITERATE
                  </text>
                  <text x="14" y="60" font-size="9.5" fill="#8a8a93" letter-spacing="1">
                    weekly review
                  </text>
                </g>
              </g>
              <g stroke="#ff3838" stroke-width="1.5" fill="none" marker-end="url(#ammloop-arr)">
                <line x1="210" y1="180" x2="252" y2="180" />
                <line x1="410" y1="180" x2="452" y2="180" />
                <path d="M610,140 Q645,100 645,110" />
                <path d="M645,250 Q645,260 615,222" />
                <path
                  d="M580,295 Q380,330 130,250 Q90,235 130,222"
                  stroke-dasharray="4 4"
                />
              </g>
              <text
                x="380"
                y="345"
                text-anchor="middle"
                font-family="JetBrains Mono, monospace"
                font-size="9.5"
                fill="#53535a"
                letter-spacing="1"
              >
                {@copy.loop_diagram.note}
              </text>
            </svg>
          </div>
        </figure>
      </div>
    </section>
    """
  end

  # ─── ORIGIN ───
  defp origin_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading idx={@copy.origin.idx} name={@copy.origin.name} title={@copy.origin.title} />

        <%= for p <- @copy.origin.paragraphs do %>
          <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">{p}</p>
        <% end %>

        <blockquote class="my-15 px-9 py-8 bg-base-200 border border-primary/20 chamfer-lg relative">
          <span class="absolute top-0 left-0 w-1 h-full bg-primary [box-shadow:0_0_12px_var(--color-cms-red)]">
          </span>
          <p class="font-heading font-bold uppercase text-xl md:text-2xl lg:text-3xl leading-tight tracking-[-0.01em] m-0">
            {@copy.origin.pullquote.lead}{" "}
            <span class="text-primary">{@copy.origin.pullquote.accent}</span>{" "}
            {@copy.origin.pullquote.tail}
          </p>
          <cite class="block mt-4 font-mono text-[11px] not-italic uppercase tracking-[0.18em] text-base-content/50">
            {@copy.origin.pullquote.cite}
          </cite>
        </blockquote>
      </div>
    </section>
    """
  end

  # ─── DAILY LOOP ───
  defp daily_loop_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading
          idx={@copy.daily_loop.idx}
          name={@copy.daily_loop.name}
          title={@copy.daily_loop.title}
        />

        <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">
          {@copy.daily_loop.intro}
        </p>

        <div class="my-12 border border-primary/20 chamfer-lg bg-base-200 divide-y divide-base-300">
          <%= for step <- @copy.daily_loop.steps do %>
            <div class="grid grid-cols-[88px_1fr] gap-6 px-7 py-7 items-start">
              <div>
                <div class="font-heading font-bold text-[32px] text-primary leading-none tracking-tight">
                  {step.n}
                </div>
                <div class="font-mono text-[10px] uppercase tracking-[0.18em] text-base-content/50 mt-1.5">
                  {step.of}
                </div>
              </div>
              <div>
                <span class={[
                  "inline-block font-mono text-[9.5px] uppercase tracking-[0.16em] px-2 py-1 mb-2.5 border",
                  if(step.actor == "claude",
                    do: "text-primary border-primary/20",
                    else: "text-base-content border-base-content"
                  )
                ]}>
                  // {step.actor}
                </span>
                <h4 class="font-mono text-xs font-bold uppercase tracking-[0.16em] text-base-content m-0">
                  {step.title}
                </h4>
                <p class="text-[15.5px] leading-relaxed text-base-content/70 mt-2 mb-0">
                  {step.body}
                </p>
              </div>
            </div>
          <% end %>
        </div>

        <p class="text-[17px] leading-[1.72] text-base-content/85">{@copy.daily_loop.outro}</p>
      </div>
    </section>
    """
  end

  # ─── STACK ───
  defp stack_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24" id="stack">
        <.section_heading idx={@copy.stack.idx} name={@copy.stack.name} title={@copy.stack.title} />

        <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">{@copy.stack.intro}</p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-[18px] mt-10">
          <%= for mcp <- @copy.stack.mcps do %>
            <div class="bg-base-200 border border-primary/20 chamfer-md p-7 relative flex flex-col gap-3.5 group overflow-hidden">
              <span class="absolute top-0 left-0 h-[2px] bg-primary w-0 group-hover:w-full transition-[width] duration-300">
              </span>
              <div class="flex justify-between items-start">
                <div>
                  <div class="font-mono text-[11px] uppercase tracking-[0.1em] text-base-content/50">
                    {mcp.role}
                  </div>
                  <div class="font-heading font-bold uppercase text-lg tracking-[-0.01em] mt-1">
                    {mcp.name}
                  </div>
                </div>
                <span class="font-mono text-[9px] uppercase tracking-[0.18em] text-primary border border-primary/20 px-2 py-1">
                  {mcp.pill}
                </span>
              </div>
              <p class="text-[14.5px] leading-relaxed text-base-content/70 m-0">{mcp.desc}</p>
              <div class="flex justify-between font-mono text-[11.5px] text-primary pt-2 border-t border-base-300">
                <span class="text-base-content/50">github</span>
                <span>{mcp.repo}</span>
              </div>
            </div>
          <% end %>
        </div>

        <h3 class="font-mono text-sm font-bold uppercase tracking-[0.14em] text-base-content mt-12 mb-3">
          {@copy.stack.seo_section.sub}
        </h3>

        <%= for p <- @copy.stack.seo_section.paragraphs do %>
          <p class="text-[17px] leading-[1.72] mt-4 text-base-content/85">{Phoenix.HTML.raw(p)}</p>
        <% end %>
      </div>
    </section>
    """
  end

  # ─── MISTAKES ───
  defp mistakes_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading
          idx={@copy.mistakes.idx}
          name={@copy.mistakes.name}
          title={@copy.mistakes.title}
        />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-9">
          <%= for mk <- @copy.mistakes.items do %>
            <div class="bg-base-300 border border-primary/20 chamfer-md p-6">
              <div class="flex items-center gap-2 font-mono text-[11px] uppercase tracking-[0.18em] text-primary mb-2.5">
                <span class="text-sm">⚠</span>
                <span>{mk.label}</span>
              </div>
              <h4 class="font-heading font-bold uppercase text-lg tracking-[-0.01em] leading-tight mb-2.5 m-0">
                {mk.title}
              </h4>
              <p class="text-[14.5px] leading-relaxed text-base-content/70 m-0">{mk.body}</p>
            </div>
          <% end %>
        </div>

        <h3 class="font-mono text-sm font-bold uppercase tracking-[0.14em] text-base-content mt-12 mb-3">
          {@copy.mistakes.bonus.sub}
        </h3>
        <p class="text-[17px] leading-[1.72] text-base-content/85">{@copy.mistakes.bonus.body}</p>
      </div>
    </section>
    """
  end

  # ─── RESULTS ───
  defp results_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24" id="results">
        <.section_heading
          idx={@copy.results.idx}
          name={@copy.results.name}
          title={@copy.results.title}
        />

        <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">{@copy.results.intro}</p>

        <div class="mt-12 border border-primary/20 chamfer-lg bg-base-200">
          <div class="px-7 py-4 border-b border-base-300 flex justify-between items-center font-mono text-[10.5px] uppercase tracking-[0.22em] text-base-content/50">
            <span class="text-primary">{@copy.results.snapshot.head_left}</span>
            <span>{@copy.results.snapshot.head_right}</span>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-3">
            <%= for {stat, i} <- Enum.with_index(@copy.results.snapshot.stats) do %>
              <div class={[
                "px-7 py-7",
                "border-b border-base-300",
                rem(i, 3) != 2 && "md:border-r md:border-base-300",
                i >= length(@copy.results.snapshot.stats) - 3 && "md:border-b-0",
                i == length(@copy.results.snapshot.stats) - 1 && "border-b-0"
              ]}>
                <div class="font-heading font-bold text-[36px] leading-none tracking-tight">
                  {stat.value}<span :if={stat.unit} class="text-sm text-primary ml-1">{stat.unit}</span>
                </div>
                <div class="font-mono text-[10.5px] uppercase tracking-[0.16em] text-base-content/50 mt-2.5">
                  {stat.label}
                </div>
                <div class="text-[13px] text-base-content/70 mt-2 leading-relaxed">{stat.ctx}</div>
              </div>
            <% end %>
          </div>
        </div>

        <h3 class="font-mono text-sm font-bold uppercase tracking-[0.14em] text-base-content mt-10 mb-3">
          {@copy.results.findings_sub}
        </h3>

        <div class="border border-primary/20 chamfer-md divide-y divide-base-300">
          <%= for f <- @copy.results.findings do %>
            <div class="grid grid-cols-1 md:grid-cols-[160px_1fr] gap-5 px-6 py-4">
              <div class="font-mono text-[10.5px] uppercase tracking-[0.16em] text-primary pt-1">
                {f.label}
              </div>
              <div class="text-[14.5px] leading-relaxed text-base-content">
                <strong class="text-base-content font-semibold">{f.lead}</strong> {f.body}
              </div>
            </div>
          <% end %>
        </div>

        <p class="text-[17px] leading-[1.72] mt-7 text-base-content/85">{@copy.results.closer}</p>
      </div>
    </section>
    """
  end

  # ─── FILES ───
  defp files_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading
          idx={@copy.files_section.idx}
          name={@copy.files_section.name}
          title={@copy.files_section.title}
        />

        <%= for p <- @copy.files_section.paragraphs do %>
          <p class="text-[17px] leading-[1.72] mt-5 text-base-content/85">{p}</p>
        <% end %>
      </div>
    </section>
    """
  end

  # ─── INSTALL ───
  defp install_section(assigns) do
    ~H"""
    <section id="install">
      <div class="max-w-3xl mx-auto px-6 mt-16">
        <.install_card
          harness="marketmyspec"
          accent="bdd"
          brief_url={~p"/products/market-my-spec"}
          brief_label="Read the brief →"
          footer_label="byok · plain markdown in your repo"
        />
      </div>
    </section>
    """
  end

  # ─── CTA ───
  defp cta_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-16">
        <div class="px-8 py-10 md:px-10 md:py-12 border border-primary chamfer-md bg-primary/5">
          <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-primary mb-4">
            {@copy.cta.eyebrow}
          </p>
          <h3 class="font-heading font-bold uppercase text-2xl md:text-3xl leading-tight tracking-[-0.02em] m-0">
            {@copy.cta.title}
          </h3>
          <p class="text-[15px] text-base-content/70 mt-4 mb-8 max-w-[54ch]">{@copy.cta.body}</p>
          <div class="flex flex-wrap items-center gap-5">
            <a href={@copy.cta.primary.href} class="btn btn-primary">{@copy.cta.primary.label}</a>
            <a
              href={@copy.cta.secondary.href}
              class="font-mono text-sm uppercase tracking-[0.14em] text-base-content border-b border-primary/30 hover:text-primary hover:border-primary transition pb-0.5"
            >
              {@copy.cta.secondary.label}
            </a>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── FAQ ───
  defp faq_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading idx={@copy.faq.idx} name={@copy.faq.name} title={@copy.faq.title} />

        <div class="mt-12 border-t border-primary/20">
          <%= for {item, i} <- Enum.with_index(@copy.faq.items) do %>
            <details class="border-b border-primary/20 group" open={i == 0}>
              <summary class="cursor-pointer list-none py-6 flex justify-between items-center gap-6 font-heading font-bold uppercase text-lg tracking-[-0.01em] text-base-content hover:text-primary transition">
                <span class="flex-1">{item.question}</span>
                <span class="font-mono text-xl text-primary transition-transform group-open:rotate-45 flex-shrink-0">
                  +
                </span>
              </summary>
              <div class="pb-6 pl-9 text-[15.5px] text-base-content/70 leading-relaxed">
                {Phoenix.HTML.raw(item.answer)}
              </div>
            </details>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  # ─── SOURCES ───
  defp sources_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-24">
        <.section_heading
          idx={@copy.sources.idx}
          name={@copy.sources.name}
          title={@copy.sources.title}
        />

        <ol class="list-none p-0 m-0 mt-12">
          <%= for {item, i} <- Enum.with_index(@copy.sources.items, 1) do %>
            <li class="grid grid-cols-[36px_1fr] gap-5 py-3.5 border-b border-base-300">
              <span class="font-mono text-[11px] tracking-[0.16em] text-primary pt-1">
                {String.pad_leading(Integer.to_string(i), 2, "0")}
              </span>
              <div>
                <span class="text-base-content font-medium text-[14.5px]">{item.title}</span>
                <span class="block text-base-content/50 font-mono text-[11.5px] mt-1.5 uppercase tracking-[0.05em]">
                  {item.note}
                </span>
              </div>
            </li>
          <% end %>
        </ol>
      </div>
    </section>
    """
  end

  # ─── FOOTER CLOSING ───
  defp footer_section(assigns) do
    ~H"""
    <section>
      <div class="max-w-3xl mx-auto px-6 mt-20 pt-14 pb-20 border-t border-primary/20 signal-top">
        <p class="border-l-2 border-primary pl-5 py-1.5 italic text-base-content/70 leading-relaxed max-w-[62ch]">
          {@copy.footer_closing}
        </p>
      </div>
    </section>
    """
  end

  # ─── helpers ───

  attr :idx, :string, required: true
  attr :name, :string, required: true
  attr :title, :string, required: true

  defp section_heading(assigns) do
    ~H"""
    <h2 class="font-heading font-bold uppercase text-2xl md:text-4xl lg:text-5xl leading-tight tracking-[-0.02em] mt-16 mb-4 relative pt-8">
      <span class="absolute top-0 left-0 w-16 h-[2px] bg-primary [box-shadow:0_0_10px_var(--color-cms-red)]">
      </span>
      <span class="block font-mono text-[11px] font-medium tracking-[0.22em] text-primary uppercase mb-3.5">
        // {@idx} · {@name}
      </span>
      {@title}
    </h2>
    """
  end

  defp strip_html(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
