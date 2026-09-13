defmodule CodeMySpecWeb.ContentLive.Pages.Methodology do
  @moduledoc """
  Renders the /methodology marketing page — the CodeMySpec method as a
  six-phase loop. Static LiveView: copy is loaded at compile time from
  methodology_copy.exs, mount/2 emits SEO meta and JSON-LD (TechArticle +
  BreadcrumbList + FAQPage), and a colocated `.DeepContentRead` hook fires
  a GA event after 60s on page.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  # Load copy data at compile time
  @external_resource copy_path =
                       Path.join(__DIR__, "methodology_copy.exs")

  @copy (case Code.eval_file(copy_path) do
           {copy, _} -> copy
         end)

  # Per-phase accent palette. The `--color-cms-phase-*` tokens were removed
  # from app.css, so the six phases carry their own mid-tone hexes here.
  # Chosen to read against both the light limestone and dark near-black
  # grounds of the Workshop theme (used for borders, badges, and SVG nodes,
  # never as long-form body text).
  @phase_colors ~w(#2a8f88 #b0793a #6f8f4a #c99a3f #4a86a8 #b55f45)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :phase_colors, @phase_colors)

    ~H"""
    <Layouts.marketing current_path={assigns[:current_path]} flash={@flash} current_scope={@current_scope}>
      <div id="methodology-page" phx-hook=".DeepContentRead">
        {hero_section(assigns)}
        {diagram_section(assigns)}
        {problem_section(assigns)}
        {solution_section(assigns)}
        {phases_section(assigns)}
        {proof_section(assigns)}
        {cta_section(assigns)}
        {faq_section(assigns)}
        {final_cta_section(assigns)}
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DeepContentRead">
        export default {
          mounted() {
            this._timer = setTimeout(() => {
              if (typeof gtag === "function") {
                gtag('event', 'deep_content_read', {
                  content_category: document.title,
                  page_path: window.location.pathname
                });
              }
            }, 60000);
          },
          destroyed() {
            clearTimeout(this._timer);
          }
        }
      </script>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    base_url = CodeMySpecWeb.Endpoint.url()

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "TechArticle",
          "@id" => "#{base_url}/methodology",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/methodology",
          "image" => %{
            "@type" => "ImageObject",
            "url" => CodeMySpecWeb.ImageUrl.image_url("og-methodology.png", base_url),
            "width" => 1200,
            "height" => 630
          },
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
          "mainEntityOfPage" => %{
            "@type" => "WebPage",
            "@id" => "#{base_url}/methodology"
          },
          "datePublished" => "2026-03-01T00:00:00Z",
          "dateModified" => "2026-04-04T00:00:00Z",
          "proficiencyLevel" => "Expert",
          "articleSection" => "Methodology"
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{
              "@type" => "ListItem",
              "position" => 2,
              "name" => "Methodology",
              "item" => "#{base_url}/methodology"
            }
          ]
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "FAQPage",
          "mainEntity" =>
            Enum.map(@copy.faq, fn item ->
              %{
                "@type" => "Question",
                "name" => item.question,
                "acceptedAnswer" => %{
                  "@type" => "Answer",
                  "text" => item.answer
                }
              }
            end)
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:canonical_url, "#{base_url}/methodology")
     |> assign(:og_image, CodeMySpecWeb.ImageUrl.image_url("og-methodology.png", base_url))
     |> assign(:og_type, "article")
     |> assign(:article_published_time, "2026-03-01T00:00:00Z")
     |> assign(:json_ld, json_ld)}
  end

  # ─── HERO ───
  defp hero_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 bg-base-100">
      <div class="max-w-3xl mx-auto px-6 pt-20 pb-20 lg:pt-24 lg:pb-24">
        <div class="flex items-center gap-3 mb-7">
          <span class="badge badge-primary badge-outline">The method</span>
          <span class="text-sm text-base-content/60">v1.0 · production</span>
        </div>

        <h1 class="font-bold text-4xl md:text-5xl lg:text-6xl leading-[1.02] tracking-tight">
          The CodeMySpec <span class="text-primary">Method.</span>
        </h1>
        <p class="font-bold text-2xl md:text-[32px] tracking-tight leading-tight mt-6">
          Generating code is the easy part. <span class="text-primary">Shipping is the loop.</span>
        </p>
        <p class="text-lg text-base-content mt-6 max-w-[64ch] leading-relaxed">
          AI can write code. Shipping working software takes stories, architecture, BDD specs, verified implementations, and QA. Six phases, every artifact verified by the next, problems routed back to the right level. Here's the full loop.
        </p>
        <p class="text-sm text-base-content/60 mt-6">
          By
          <a href={~p"/author/john-davenport"} class="link link-primary">John Davenport</a>
          · the engineer who built CodeMySpec with CodeMySpec
        </p>

        <div class="mt-9 flex flex-wrap items-center gap-5">
          <a href="#install" class="btn btn-primary">Install CodeMySpec</a>
          <a href="#diagram" class="link link-hover text-base-content/80 font-medium">
            See the loop ↓
          </a>
        </div>
      </div>
    </section>
    """
  end

  # ─── DIAGRAM (SVG loop) ───
  defp diagram_section(assigns) do
    ~H"""
    <section id="diagram" class="border-b border-base-300 bg-base-100">
      <div class="max-w-7xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="01" name="the loop" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Six phases. <span class="text-primary">Every artifact verified.</span>
        </h2>
        <p class="text-lg text-base-content/70 mt-6 max-w-[64ch] leading-relaxed">
          Stories define what done looks like. Each subsequent phase verifies its predecessor. When verification fails, the issue routes back to the level that owns it — story, design, or code. The forward path is solid. The feedback edges are dashed. That's the whole methodology in one diagram.
        </p>

        <div class="mt-16 overflow-x-auto rounded-box border border-base-300 bg-base-200 p-6">
          <svg
            viewBox="0 0 1300 380"
            xmlns="http://www.w3.org/2000/svg"
            class="block w-full h-auto min-w-[900px]"
            role="img"
            aria-label="Loop diagram: six phases connected forward, with feedback edges from QA and BDD Verify routing back to Stories, Architecture, and Implementation."
          >
            <defs>
              <marker
                id="arr"
                viewBox="0 0 10 10"
                refX="8"
                refY="5"
                markerWidth="6"
                markerHeight="6"
                orient="auto"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--color-primary)" />
              </marker>
              <marker
                id="arr-fb"
                viewBox="0 0 10 10"
                refX="8"
                refY="5"
                markerWidth="7"
                markerHeight="7"
                orient="auto"
              >
                <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--color-secondary)" />
              </marker>
            </defs>

            <g
              stroke="var(--color-primary)"
              stroke-width="1.5"
              fill="none"
              marker-end="url(#arr)"
            >
              <line x1="150" y1="180" x2="245" y2="180" />
              <line x1="345" y1="180" x2="440" y2="180" />
              <line x1="540" y1="180" x2="635" y2="180" />
              <line x1="735" y1="180" x2="830" y2="180" />
              <line x1="930" y1="180" x2="1025" y2="180" />
            </g>

            <g
              stroke="var(--color-secondary)"
              stroke-width="1.5"
              fill="none"
              stroke-dasharray="6 4"
              marker-end="url(#arr-fb)"
              style="animation: dash-flow 1.6s linear infinite;"
            >
              <path d="M 1075 145 C 1075 50, 100 50, 100 145" />
              <path d="M 880 145 C 880 90, 295 90, 295 145" />
              <path d="M 870 215 C 830 250, 705 250, 685 215" />
            </g>

            <g font-family="IBM Plex Sans, system-ui, sans-serif">
              <.phase_node x="50" color="#2a8f88" num="01" title="Stories" verb="define" size="14" />
              <.phase_node x="245" color="#b0793a" num="02" title="Arch" verb="design" size="13" />
              <.phase_node
                x="440"
                color="#6f8f4a"
                num="03"
                title="BDD Specs"
                verb="contract"
                size="12"
              />
              <.phase_node
                x="635"
                color="#c99a3f"
                num="04"
                title="Impl"
                verb="spec → test → code"
                size="12"
              />
              <.phase_node
                x="830"
                color="#4a86a8"
                num="05"
                title="Verify"
                verb="bdd run"
                size="13"
              />
              <.phase_node
                x="1025"
                color="#b55f45"
                num="06"
                title="QA"
                verb="browser"
                size="14"
              />
            </g>

            <g>
              <line
                x1="1125"
                y1="180"
                x2="1200"
                y2="180"
                stroke="var(--color-primary)"
                stroke-width="2"
                marker-end="url(#arr)"
              />
              <text
                x="1215"
                y="185"
                font-family="IBM Plex Sans, system-ui, sans-serif"
                font-weight="700"
                font-size="16"
                fill="var(--color-primary)"
              >
                Ship
              </text>
            </g>

            <g
              font-family="IBM Plex Sans, system-ui, sans-serif"
              font-size="10"
              fill="var(--color-secondary)"
            >
              <text x="600" y="42" text-anchor="middle">Requirements gap → Story</text>
              <text x="600" y="82" text-anchor="middle">Spec mismatch → Design</text>
              <text x="775" y="262" text-anchor="middle">Code bug → Impl</text>
            </g>
          </svg>
        </div>

        <div class="mt-8 flex flex-wrap gap-6 text-sm text-base-content/70">
          <div class="flex items-center gap-2">
            <span class="w-6 h-[2px] bg-primary"></span>
            <span>Forward · artifact passed</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-6 h-[2px] bg-[image:repeating-linear-gradient(90deg,var(--color-secondary)_0,var(--color-secondary)_4px,transparent_4px,transparent_7px)]">
            </span>
            <span>Feedback · routed by root cause</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # A single node in the loop diagram: rounded card, phase-colored border,
  # small phase number, bold title, muted verb.
  attr :x, :string, required: true
  attr :color, :string, required: true
  attr :num, :string, required: true
  attr :title, :string, required: true
  attr :verb, :string, required: true
  attr :size, :string, default: "13"

  defp phase_node(assigns) do
    ~H"""
    <g transform={"translate(#{@x},140)"}>
      <rect
        width="100"
        height="80"
        rx="10"
        fill="var(--color-base-100)"
        stroke={@color}
        stroke-width="2"
      />
      <text x="50" y="24" text-anchor="middle" font-size="9" font-weight="600" fill={@color}>
        Phase {@num}
      </text>
      <text
        x="50"
        y="47"
        text-anchor="middle"
        font-weight="700"
        font-size={@size}
        fill="var(--color-base-content)"
      >
        {@title}
      </text>
      <text x="50" y="66" text-anchor="middle" font-size="9" fill="var(--color-base-content)" opacity="0.55">
        {@verb}
      </text>
    </g>
    """
  end

  # ─── PROBLEM ───
  defp problem_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 bg-base-200">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="02" name="the problem" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight max-w-[24ch]">
          Code generation <span class="text-primary">isn't software.</span>
        </h2>
        <p class="text-lg leading-relaxed text-base-content mt-6 max-w-[64ch]">
          {@copy.problem.description}
        </p>

        <div class="mt-14 grid grid-cols-1 md:grid-cols-3 gap-5">
          <%= for {point, i} <- Enum.with_index(@copy.problem.points, 1) do %>
            <div class="card bg-base-100 border border-base-300 shadow-sm">
              <div class="card-body gap-3 p-7">
                <div class="text-sm font-semibold text-primary tabular-nums">
                  {String.pad_leading(Integer.to_string(i), 2, "0")}
                </div>
                <h3 class="font-bold text-lg leading-tight tracking-tight">
                  {point.title}
                </h3>
                <p class="text-[14.5px] text-base-content/70 leading-relaxed">{point.description}</p>
              </div>
            </div>
          <% end %>
        </div>

        <div class="mt-10 max-w-[760px] rounded-box border-l-4 border-primary bg-base-100 px-6 py-5 text-base text-base-content">
          {@copy.problem.conclusion}
        </div>
      </div>
    </section>
    """
  end

  # ─── SOLUTION ───
  defp solution_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 bg-base-100">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="03" name="the solution" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          The <span class="text-primary">full loop.</span>
        </h2>

        <div class="card bg-base-200 border border-base-300 shadow-sm mt-12">
          <div class="card-body p-10 md:p-12">
            <p class="text-lg text-base-content leading-relaxed mb-6 max-w-[68ch]">
              {@copy.solution.description}
            </p>

            <ul class="steps steps-vertical w-full">
              <%= for item <- @copy.solution.approach do %>
                <li class="step step-primary text-left">
                  <span class="text-base text-base-content leading-snug ml-2">{item}</span>
                </li>
              <% end %>
            </ul>

            <div class="mt-8 pt-7 border-t border-base-300 font-bold text-xl md:text-[28px] tracking-tight leading-snug">
              Stories<span class="text-primary mx-1.5">→</span>Architecture<span class="text-primary mx-1.5">→</span>BDD
              Specs<span class="text-primary mx-1.5">→</span>Impl<span class="text-primary mx-1.5">→</span>QA<span class="text-primary mx-1.5">→</span><span class="text-primary">Ship.</span>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── PHASES (tabbed panels) ───
  defp phases_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 bg-base-200">
      <div class="max-w-7xl mx-auto px-6 py-24 lg:py-32">
        <.eyebrow idx="04" name="the six phases" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Each phase is <span class="text-primary">a real artifact.</span>
        </h2>

        <div role="tablist" class="tabs tabs-lift mt-14">
          <%= for {phase, i} <- Enum.with_index(@copy.phases) do %>
            <input
              type="radio"
              name="methodology_phases"
              role="tab"
              class="tab font-semibold"
              aria-label={"#{String.pad_leading(Integer.to_string(phase.number), 2, "0")} · #{phase.title}"}
              checked={i == 0}
            />
            <div
              role="tabpanel"
              class="tab-content bg-base-100 border-base-300 rounded-box p-8 md:p-11"
            >
              <div
                class="border-l-4 pl-6"
                style={"border-color: #{Enum.at(@phase_colors, i)};"}
              >
                <div class="flex justify-between items-center flex-wrap gap-3 mb-6 pb-5 border-b border-base-300">
                  <span class="text-sm text-base-content/60">
                    Phase {String.pad_leading(Integer.to_string(phase.number), 2, "0")} of 06
                  </span>
                  <span
                    class="badge badge-outline"
                    style={"color: #{Enum.at(@phase_colors, i)}; border-color: #{Enum.at(@phase_colors, i)};"}
                  >
                    {phase.title}
                  </span>
                </div>

                <h3 class="font-bold text-3xl md:text-[34px] tracking-tight mb-2">
                  {phase.title}
                </h3>
                <p class="text-base text-base-content/60 italic mb-5">
                  {phase.tagline}
                </p>
                <p class="text-base text-base-content leading-[1.7] mb-7 max-w-[64ch]">
                  {phase.description}
                </p>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 mb-7">
                  <%= for highlight <- phase.highlights do %>
                    <div class="flex gap-3 items-start text-sm text-base-content/80 leading-snug rounded-box bg-base-200 py-2.5 px-3.5">
                      <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
                      <span>{highlight}</span>
                    </div>
                  <% end %>
                </div>

                <div class="flex justify-between items-center flex-wrap gap-3.5 pt-5 border-t border-base-300">
                  <div class="text-sm text-base-content/60">
                    Creates
                    <span class="block mt-1 text-[13px] text-base-content">
                      {phase.creates}
                    </span>
                  </div>
                  <.guide_link guide={phase.guide} />
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  # ─── PROOF ───
  defp proof_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 bg-base-100">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="05" name="the proof" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Built with the loop. <span class="text-primary">Shipped with the loop.</span>
        </h2>

        <div class="card bg-base-200 border border-base-300 shadow-sm mt-12">
          <div class="card-body p-10 md:p-11">
            <p class="text-[17px] text-base-content leading-relaxed mb-7 max-w-[64ch]">
              {@copy.proof.description}
            </p>

            <ul class="grid grid-cols-1 md:grid-cols-2 gap-3.5 list-none p-0 mb-8">
              <%= for item <- @copy.proof.evidence do %>
                <li class="text-[14.5px] text-base-content leading-snug rounded-box bg-base-100 py-3 px-4 flex gap-3 items-start">
                  <.icon name="hero-check-circle" class="size-5 text-primary shrink-0" />
                  <span>{item}</span>
                </li>
              <% end %>
            </ul>

            <p class="pt-6 border-t border-base-300 text-base text-base-content/80 leading-snug">
              {@copy.proof.tagline}
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── CTA / Install ───
  defp cta_section(assigns) do
    ~H"""
    <section id="install" class="border-b border-base-300 bg-base-200">
      <div class="max-w-7xl mx-auto px-6 py-28 lg:py-32">
        <.eyebrow idx="06" name="start the loop" />
        <div class="mt-6 grid lg:grid-cols-[1.2fr_1fr] gap-12 items-center">
          <div>
            <h2 class="font-bold text-4xl md:text-6xl leading-[1.02] tracking-tight max-w-[14ch]">
              Run the loop on <span class="text-primary">your codebase.</span>
            </h2>
            <p class="text-lg text-base-content mt-6 max-w-[50ch] leading-relaxed">
              Phoenix-native today, ~30 minutes to set up. Install the plugin, run the story interview, and you're in phase 01.
            </p>
            <div class="mt-9 flex flex-wrap items-center gap-5">
              <a href={~p"/users/register"} class="btn btn-primary">Try CodeMySpec</a>
              <a
                href={ExternalLinks.cal_john()}
                class="link link-hover text-base-content/80 font-medium"
                data-event-label="cta-service-inquiry-methodology"
              >
                Talk to John →
              </a>
            </div>
          </div>

          <.install_card
            harness="codemyspec"
            brief_url={~p"/developers"}
            brief_label="Read the brief →"
            footer_label="claude code · v1.0"
            location="methodology"
          />
        </div>
      </div>
    </section>
    """
  end

  # ─── FAQ ───
  defp faq_section(assigns) do
    ~H"""
    <section class="bg-base-100">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="07" name="faq" />
        <h2 class="mt-3 font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight mb-8">
          Questions <span class="text-primary">we get.</span>
        </h2>

        <div class="flex flex-col gap-3">
          <%= for {item, i} <- Enum.with_index(@copy.faq) do %>
            <div class="collapse collapse-arrow bg-base-200 border border-base-300 rounded-box">
              <input type="checkbox" checked={i == 0} />
              <div class="collapse-title font-medium text-[15px]">
                {item.question}
              </div>
              <div class="collapse-content text-base text-base-content/70 leading-relaxed max-w-[72ch]">
                {item.answer}
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </section>
    """
  end

  # ─── FINAL CTA (post-FAQ) ───
  # Picks up the deep-engaged readers who finish the FAQ at the bottom of
  # the page and currently have no action button without scrolling back up
  # (CRO recommendation 2026-05-20). Smaller than the mid-page install
  # section — the FAQ already qualified them.
  defp final_cta_section(assigns) do
    ~H"""
    <section class="border-t border-base-300 bg-base-200">
      <div class="max-w-3xl mx-auto px-6 py-20 lg:py-24 text-center">
        <.eyebrow idx="08" name="ready" align="center" />
        <h2 class="mt-3 font-bold text-3xl md:text-4xl leading-[1.08] tracking-tight max-w-[20ch] mx-auto">
          Now run the loop <span class="text-primary">on your codebase.</span>
        </h2>
        <p class="text-base text-base-content/70 mt-5 max-w-[48ch] mx-auto leading-relaxed">
          ~30 minutes to set up. One Claude Code plugin install. BYO model, BYO keys.
        </p>
        <div class="mt-9 flex flex-wrap justify-center items-center gap-5">
          <.link href={~p"/users/register"} class="btn btn-primary">
            Get started
          </.link>
          <a href="#install" class="link link-hover text-base-content/80 font-medium">
            See install commands ↑
          </a>
        </div>
        <p class="mt-8 text-sm text-base-content/60">
          Comparing approaches first? Read the neutral
          <.link navigate="/blog/spec-driven-development" class="link link-primary">
            guide to spec-driven development
          </.link>
          covering the whole tool landscape.
        </p>
      </div>
    </section>
    """
  end

  # ─── Helpers ───
  attr :guide, :map, required: true

  defp guide_link(%{guide: %{status: :published}} = assigns) do
    ~H"""
    <a href={@guide.url} class="link link-primary text-sm font-medium">
      {@guide.title} →
    </a>
    """
  end

  defp guide_link(%{guide: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <span class="badge badge-ghost">
      Coming Soon
    </span>
    """
  end
end
