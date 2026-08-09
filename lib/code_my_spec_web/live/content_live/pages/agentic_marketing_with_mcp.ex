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
    <Layouts.marketing current_path={assigns[:current_path]} flash={@flash} current_scope={@current_scope}>
      <div id="agentic-marketing-page">
        <div
          id="reading-progress"
          phx-hook=".ReadingProgress"
          phx-update="ignore"
          class="fixed top-0 left-0 h-[3px] bg-primary z-50 w-0 transition-[width] duration-75 ease-linear"
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
    og_image = CodeMySpecWeb.ImageUrl.image_url("og-blog-agentic-marketing-with-mcp.png", base_url)

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "BlogPosting",
          "@id" => canonical,
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => canonical,
          "image" => %{
            "@type" => "ImageObject",
            "url" => og_image,
            "width" => 1200,
            "height" => 630
          },
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
     |> assign(:og_image, og_image)
     |> assign(:og_type, "article")
     |> assign(:article_published_time, @published_at)
     |> assign(:json_ld, json_ld)}
  end

  # ─── HERO ───
  defp hero_section(assigns) do
    ~H"""
    <section class="border-b border-base-300">
      <div class="max-w-3xl mx-auto px-6 pt-24 pb-16">
        <.eyebrow idx={@copy.hero.eyebrow_idx} name={@copy.hero.eyebrow_kind} />

        <h1 class="mt-5 font-bold tracking-tight text-4xl sm:text-5xl md:text-6xl leading-[1.05]">
          <%= for {line, i} <- Enum.with_index(@copy.hero.title_lines) do %>
            <span class={["block", i == @copy.hero.title_accent_index && "text-primary"]}>
              {line}
            </span>
          <% end %>
        </h1>

        <p class="text-lg text-base-content/70 mt-6 max-w-[62ch] leading-relaxed">
          {@copy.hero.deck}
        </p>

        <div class="mt-8 flex flex-wrap gap-2">
          <%= for item <- @copy.hero.meta do %>
            <span class="badge badge-outline gap-1 py-3">
              <span :if={item.label} class="font-medium text-base-content">{item.label}</span>
              <span :if={item.suffix} class="text-base-content/60">{item.suffix}</span>
            </span>
          <% end %>
        </div>

        <div class="card bg-base-200 border border-base-300 mt-10">
          <div class="card-body gap-2 p-6">
            <.eyebrow name="recursion note" />
            <p class="leading-relaxed m-0">{@copy.hero.recursion_note}</p>
          </div>
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
        <p class="text-xl text-base-content leading-relaxed font-medium">{@copy.lede}</p>
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
        <figure id="loop" class="card bg-base-200 border border-base-300 overflow-hidden m-0">
          <figcaption class="flex justify-between items-center gap-4 px-6 py-3.5 border-b border-base-300 text-xs text-base-content/60">
            <span class="font-semibold text-primary">{@copy.loop_diagram.fig_label}</span>
            <span>{@copy.loop_diagram.fig_caption}</span>
          </figcaption>
          <div class="p-6 overflow-x-auto">
            <ul
              class="steps steps-vertical md:steps-horizontal w-full"
              aria-label="The marketing loop: strategy, daily plan, execute, measure, iterate"
            >
              <li class="step step-primary">
                <div class="text-left md:text-center px-2">
                  <div class="font-bold">Strategy</div>
                  <div class="text-xs text-base-content/60">/marketing-strategy</div>
                </div>
              </li>
              <li class="step step-primary">
                <div class="text-left md:text-center px-2">
                  <div class="font-bold">Daily Plan</div>
                  <div class="text-xs text-base-content/60">/daily-plan</div>
                </div>
              </li>
              <li class="step step-primary">
                <div class="text-left md:text-center px-2">
                  <div class="font-bold">Execute</div>
                  <div class="text-xs text-base-content/60">scan · draft · post</div>
                </div>
              </li>
              <li class="step step-primary">
                <div class="text-left md:text-center px-2">
                  <div class="font-bold">Measure</div>
                  <div class="text-xs text-base-content/60">GA4 · GSC</div>
                </div>
              </li>
              <li class="step step-primary">
                <div class="text-left md:text-center px-2">
                  <div class="font-bold">Iterate</div>
                  <div class="text-xs text-base-content/60">weekly review</div>
                </div>
              </li>
            </ul>
            <p class="text-center text-xs text-base-content/50 mt-6">{@copy.loop_diagram.note}</p>
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

        <blockquote class="my-12 border-l-4 border-primary bg-base-200 rounded-r-box px-8 py-6">
          <p class="font-bold tracking-tight text-xl md:text-2xl lg:text-3xl leading-tight m-0">
            {@copy.origin.pullquote.lead}{" "}
            <span class="text-primary">{@copy.origin.pullquote.accent}</span>{" "}
            {@copy.origin.pullquote.tail}
          </p>
          <cite class="block mt-4 text-sm not-italic text-base-content/50">
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

        <div class="my-10 space-y-3">
          <%= for step <- @copy.daily_loop.steps do %>
            <div class="card bg-base-200 border border-base-300">
              <div class="card-body flex-row gap-5 p-6 items-start">
                <div class="text-center flex-shrink-0 w-14">
                  <div class="text-3xl font-bold text-primary leading-none tracking-tight">
                    {step.n}
                  </div>
                  <div class="text-[10px] text-base-content/50 mt-1.5">{step.of}</div>
                </div>
                <div class="flex-1">
                  <span class={[
                    "badge badge-sm badge-outline mb-2",
                    step.actor == "claude" && "badge-primary"
                  ]}>
                    {step.actor}
                  </span>
                  <h4 class="font-bold text-base m-0">{step.title}</h4>
                  <p class="text-base-content/70 mt-1.5 mb-0 leading-relaxed">{step.body}</p>
                </div>
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

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mt-10">
          <%= for mcp <- @copy.stack.mcps do %>
            <div class="card bg-base-200 border border-base-300 hover:shadow-md transition-shadow">
              <div class="card-body gap-3 p-6">
                <div class="flex justify-between items-start gap-3">
                  <div>
                    <div class="text-xs text-base-content/50">{mcp.role}</div>
                    <div class="font-bold text-lg tracking-tight mt-0.5">{mcp.name}</div>
                  </div>
                  <span class="badge badge-primary badge-outline badge-sm flex-shrink-0">
                    {mcp.pill}
                  </span>
                </div>
                <p class="text-sm leading-relaxed text-base-content/70 m-0">{mcp.desc}</p>
                <div class="flex justify-between items-center text-xs pt-2 border-t border-base-300">
                  <span class="text-base-content/50">github</span>
                  <span class="font-mono text-primary">{mcp.repo}</span>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <h3 class="font-bold tracking-tight text-xl mt-12 mb-3">
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
            <div class="card bg-warning/5 border border-warning/20">
              <div class="card-body gap-2.5 p-6">
                <div class="flex items-center gap-2 text-warning">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                  <span class="text-xs font-semibold uppercase tracking-[0.14em]">{mk.label}</span>
                </div>
                <h4 class="font-bold tracking-tight text-lg leading-tight m-0">{mk.title}</h4>
                <p class="text-sm leading-relaxed text-base-content/70 m-0">{mk.body}</p>
              </div>
            </div>
          <% end %>
        </div>

        <h3 class="font-bold tracking-tight text-xl mt-12 mb-3">
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

        <div class="card bg-base-200 border border-base-300 mt-10 overflow-hidden">
          <div class="flex justify-between items-center gap-4 px-6 py-3.5 border-b border-base-300 text-xs text-base-content/60">
            <span class="font-semibold text-primary">{@copy.results.snapshot.head_left}</span>
            <span>{@copy.results.snapshot.head_right}</span>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-3 p-4">
            <%= for stat <- @copy.results.snapshot.stats do %>
              <div class="rounded-box bg-base-100 border border-base-300 p-5">
                <div class="text-4xl font-bold leading-none tracking-tight">
                  {stat.value}<span :if={stat.unit} class="text-sm text-primary ml-1">{stat.unit}</span>
                </div>
                <div class="text-xs text-base-content/50 mt-2.5">{stat.label}</div>
                <div class="text-[13px] text-base-content/70 mt-2 leading-relaxed">{stat.ctx}</div>
              </div>
            <% end %>
          </div>
        </div>

        <h3 class="font-bold tracking-tight text-xl mt-10 mb-3">
          {@copy.results.findings_sub}
        </h3>

        <div class="space-y-2">
          <%= for f <- @copy.results.findings do %>
            <div class="grid grid-cols-1 md:grid-cols-[160px_1fr] gap-2 md:gap-5 p-4 rounded-box bg-base-200 border border-base-300">
              <div class="text-xs font-semibold text-primary md:pt-0.5">{f.label}</div>
              <div class="text-[14.5px] leading-relaxed text-base-content">
                <strong class="font-semibold">{f.lead}</strong> {f.body}
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
          brief_url="https://marketmyspec.com"
          brief_label="See marketmyspec.com →"
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
        <div class="card bg-primary/5 border border-primary/20">
          <div class="card-body p-8 md:p-10 gap-0">
            <.eyebrow name={@copy.cta.eyebrow} />
            <h3 class="font-bold tracking-tight text-2xl md:text-3xl leading-tight mt-4 m-0">
              {@copy.cta.title}
            </h3>
            <p class="text-base-content/70 mt-4 mb-8 max-w-[54ch]">{@copy.cta.body}</p>
            <div class="flex flex-wrap items-center gap-4">
              <a href={@copy.cta.primary.href} class="btn btn-primary">{@copy.cta.primary.label}</a>
              <a href={@copy.cta.secondary.href} class="link link-primary">
                {@copy.cta.secondary.label}
              </a>
            </div>
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

        <div class="mt-10 border-t border-base-300">
          <%= for {item, i} <- Enum.with_index(@copy.faq.items) do %>
            <details class="collapse collapse-arrow border-b border-base-300 rounded-none" open={i == 0}>
              <summary class="collapse-title px-0 font-bold tracking-tight text-lg text-base-content">
                {item.question}
              </summary>
              <div class="collapse-content px-0 text-[15.5px] text-base-content/70 leading-relaxed">
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

        <ol class="list-none p-0 m-0 mt-10 divide-y divide-base-300">
          <%= for {item, i} <- Enum.with_index(@copy.sources.items, 1) do %>
            <li class="grid grid-cols-[36px_1fr] gap-5 py-3.5">
              <span class="text-sm tabular-nums font-semibold text-primary pt-0.5">
                {String.pad_leading(Integer.to_string(i), 2, "0")}
              </span>
              <div>
                <span class="text-base-content font-medium text-[14.5px]">{item.title}</span>
                <span class="block text-base-content/50 text-xs mt-1.5">{item.note}</span>
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
      <div class="max-w-3xl mx-auto px-6 mt-20 pt-12 pb-20 border-t border-base-300">
        <p class="border-l-4 border-primary pl-5 py-1 italic text-base-content/70 leading-relaxed max-w-[62ch]">
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
    <div class="mt-16 mb-4 pt-6">
      <.eyebrow idx={@idx} name={@name} />
      <h2 class="font-bold tracking-tight text-3xl md:text-4xl leading-tight mt-3">{@title}</h2>
    </div>
    """
  end

  defp strip_html(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
