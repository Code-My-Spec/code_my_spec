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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div id="methodology-page" class="product-page-zone hair-grid" phx-hook=".DeepContentRead">
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

      <script>
        // Stepper tabs — show one panel at a time, sync prev/next buttons
        (function() {
          const tabs = document.querySelectorAll('#methodology-page .step-tab');
          const panels = document.querySelectorAll('#methodology-page .step-panel');
          const prevBtn = document.getElementById('mth-prev-step');
          const nextBtn = document.getElementById('mth-next-step');
          if (!tabs.length) return;
          let active = 1;
          function show(n) {
            active = Math.max(1, Math.min(6, n));
            tabs.forEach(t => t.classList.toggle('is-active', +t.dataset.step === active));
            panels.forEach(p => p.style.display = (+p.dataset.step === active) ? '' : 'none');
            if (prevBtn) prevBtn.disabled = active === 1;
            if (nextBtn) nextBtn.disabled = active === 6;
          }
          tabs.forEach(t => t.addEventListener('click', () => show(+t.dataset.step)));
          if (prevBtn) prevBtn.addEventListener('click', () => show(active - 1));
          if (nextBtn) nextBtn.addEventListener('click', () => show(active + 1));
        })();
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DeepContentRead">
        export default {
          mounted() {
            const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
            this._timer = setTimeout(() => {
              fetch("/api/browser/analytics/event", {
                method: "POST",
                headers: {
                  "content-type": "application/json",
                  "x-csrf-token": csrf
                },
                body: JSON.stringify({
                  name: "deep_content_read",
                  params: {
                    content_category: document.title,
                    page_path: window.location.pathname
                  }
                }),
                keepalive: true
              }).catch(() => {});
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
    <section class="border-b border-base-300 signal-top scanlines">
      <div class="max-w-3xl mx-auto px-6 pt-20 pb-20 lg:pt-24 lg:pb-24">
        <div class="flex items-center gap-4 mb-7 font-mono text-[11px] uppercase tracking-[0.2em] text-base-content/40">
          <span class="border border-primary/30 text-primary px-2.5 py-1 chamfer-sm">
            ▸ 00 · the_method
          </span>
          <span class="text-primary">●</span><span>v1.0 · production</span>
        </div>

        <h1 class="font-heading font-bold text-4xl md:text-5xl lg:text-6xl leading-[1.02] tracking-tight">
          The CodeMySpec <span class="text-primary">Method.</span>
        </h1>
        <p class="font-heading font-bold text-2xl md:text-[32px] uppercase tracking-tight leading-tight mt-6">
          Generating code is the easy part. <span class="text-primary">Shipping is the loop.</span>
        </p>
        <p class="text-lg text-base-content mt-6 max-w-[64ch] leading-relaxed">
          AI can write code. Shipping working software takes stories, architecture, BDD specs, verified implementations, and QA. Six phases, every artifact verified by the next, problems routed back to the right level. Here's the full loop.
        </p>
        <p class="font-mono text-[11px] uppercase tracking-[0.2em] text-base-content/50 mt-6">
          By
          <a
            href={~p"/author/john-davenport"}
            class="text-primary border-b border-primary/30 hover:border-primary pb-0.5"
          >
            John Davenport
          </a>
          · the engineer who built CodeMySpec with CodeMySpec
        </p>

        <div class="mt-9 flex flex-wrap items-center gap-5">
          <a href="#install" class="btn btn-primary">▸ Install CodeMySpec</a>
          <a
            href="#diagram"
            class="font-mono text-sm uppercase tracking-[0.14em] text-base-content border-b border-primary/30 hover:text-primary hover:border-primary transition pb-0.5"
          >
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
    <section id="diagram" class="border-b border-base-300 signal-top">
      <div class="max-w-7xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="01" name="the_loop" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Six phases. <span class="text-primary">Every artifact verified.</span>
        </h2>
        <p class="text-lg text-base-content/70 mt-6 max-w-[64ch] leading-relaxed">
          Stories define what done looks like. Each subsequent phase verifies its predecessor. When verification fails, the issue routes back to the level that owns it — story, design, or code. The forward path is solid. The feedback edges are dashed. That's the whole methodology in one diagram.
        </p>

        <div class="mt-16 overflow-x-auto">
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
                <path d="M 0 0 L 10 5 L 0 10 z" fill="#f5f5f7" />
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
                <path d="M 0 0 L 10 5 L 0 10 z" fill="#ff3838" />
              </marker>
            </defs>

            <g opacity="0.08" stroke="#ff3838" stroke-width="0.5">
              <line x1="0" y1="80" x2="1300" y2="80" />
              <line x1="0" y1="180" x2="1300" y2="180" />
              <line x1="0" y1="280" x2="1300" y2="280" />
            </g>

            <g stroke="#f5f5f7" stroke-width="1.5" fill="none" marker-end="url(#arr)" opacity="0.85">
              <line x1="150" y1="180" x2="245" y2="180" />
              <line x1="345" y1="180" x2="440" y2="180" />
              <line x1="540" y1="180" x2="635" y2="180" />
              <line x1="735" y1="180" x2="830" y2="180" />
              <line x1="930" y1="180" x2="1025" y2="180" />
            </g>

            <g
              stroke="#ff3838"
              stroke-width="1.5"
              fill="none"
              stroke-dasharray="6 4"
              marker-end="url(#arr-fb)"
              opacity="0.85"
              style="animation: dash-flow 1.6s linear infinite;"
            >
              <path d="M 1075 145 C 1075 50, 100 50, 100 145" />
              <path d="M 880 145 C 880 90, 295 90, 295 145" />
              <path d="M 870 215 C 830 250, 705 250, 685 215" />
            </g>

            <g font-family="JetBrains Mono, monospace">
              <g transform="translate(50,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#ff3838" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#ff3838" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#ff3838"
                  letter-spacing="2"
                >
                  PHASE 01
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="14"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  STORIES
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">define</text>
              </g>
              <g transform="translate(245,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#fb923c" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#fb923c" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#fb923c"
                  letter-spacing="2"
                >
                  PHASE 02
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="13"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  ARCH
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">design</text>
              </g>
              <g transform="translate(440,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#22d3ee" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#22d3ee" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#22d3ee"
                  letter-spacing="2"
                >
                  PHASE 03
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="12"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  BDD SPECS
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">contract</text>
              </g>
              <g transform="translate(635,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#fde047" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#fde047" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#fde047"
                  letter-spacing="2"
                >
                  PHASE 04
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="12"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  IMPL
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">
                  spec→test→code
                </text>
              </g>
              <g transform="translate(830,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#a78bfa" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#a78bfa" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#a78bfa"
                  letter-spacing="2"
                >
                  PHASE 05
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="13"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  VERIFY
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">bdd run</text>
              </g>
              <g transform="translate(1025,140)">
                <rect width="100" height="80" fill="#0a0a0c" stroke="#34d399" stroke-width="2" />
                <rect x="0" y="0" width="100" height="3" fill="#34d399" />
                <text
                  x="50"
                  y="22"
                  text-anchor="middle"
                  font-size="9"
                  fill="#34d399"
                  letter-spacing="2"
                >
                  PHASE 06
                </text>
                <text
                  x="50"
                  y="46"
                  text-anchor="middle"
                  font-family="Space Mono, monospace"
                  font-weight="700"
                  font-size="14"
                  fill="#f5f5f7"
                  letter-spacing="-0.5"
                >
                  QA
                </text>
                <text x="50" y="65" text-anchor="middle" font-size="9" fill="#8a8a93">browser</text>
              </g>
            </g>

            <g>
              <line
                x1="1125"
                y1="180"
                x2="1200"
                y2="180"
                stroke="#ff3838"
                stroke-width="2"
                marker-end="url(#arr-fb)"
              />
              <text
                x="1215"
                y="185"
                font-family="Space Mono, monospace"
                font-weight="700"
                font-size="16"
                fill="#ff3838"
                letter-spacing="1"
              >
                SHIP
              </text>
            </g>

            <g
              font-family="JetBrains Mono, monospace"
              font-size="9"
              fill="#ff3838"
              letter-spacing="1.5"
            >
              <text x="600" y="42" text-anchor="middle">REQUIREMENTS GAP → STORY</text>
              <text x="600" y="82" text-anchor="middle">SPEC MISMATCH → DESIGN</text>
              <text x="775" y="262" text-anchor="middle">CODE BUG → IMPL</text>
            </g>
          </svg>
        </div>

        <div class="mt-8 flex flex-wrap gap-5 font-mono text-[11px] uppercase tracking-[0.18em] text-base-content/70">
          <div class="flex items-center gap-2">
            <span class="w-[22px] h-[2px] bg-base-content"></span>
            <span>forward · artifact passed</span>
          </div>
          <div class="flex items-center gap-2">
            <span class="w-[22px] h-[2px] bg-[image:linear-gradient(90deg,var(--color-cms-red)_50%,transparent_50%)] bg-[length:6px_2px]">
            </span>
            <span>feedback · routed by root cause</span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── PROBLEM ───
  defp problem_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 signal-top bg-gradient-to-b from-base-100 via-base-200/50 to-base-100">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="02" name="the_problem" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight max-w-[24ch]">
          Code generation <span class="text-primary">isn't software.</span>
        </h2>
        <p class="text-lg leading-relaxed text-base-content mt-6 max-w-[64ch]">
          {@copy.problem.description}
        </p>

        <div class="mt-14 grid grid-cols-1 md:grid-cols-3 gap-[18px]">
          <%= for {point, i} <- Enum.with_index(@copy.problem.points, 1) do %>
            <div class="bg-base-200 border border-primary/20 chamfer-md p-7 relative">
              <span class="absolute top-0 left-0 w-full h-[2px] bg-primary"></span>
              <div class="font-mono text-[11px] uppercase tracking-[0.22em] text-primary mb-3.5">
                ▸ {String.pad_leading(Integer.to_string(i), 2, "0")}
              </div>
              <h3 class="font-heading font-bold text-lg leading-tight tracking-tight mb-3">
                {point.title}
              </h3>
              <p class="text-[14.5px] text-base-content/70 leading-relaxed">{point.description}</p>
            </div>
          <% end %>
        </div>

        <p class="mt-10 px-6 py-5 border border-primary bg-primary/5 chamfer-md max-w-[760px] font-mono text-sm text-base-content">
          <span class="text-primary">// </span>{@copy.problem.conclusion}
        </p>
      </div>
    </section>
    """
  end

  # ─── SOLUTION ───
  defp solution_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 signal-top">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="03" name="the_solution" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          The <span class="text-primary">full loop.</span>
        </h2>

        <div class="mt-12 bg-gradient-to-b from-base-200 to-base-100 border border-primary chamfer-lg p-10 md:p-12 relative">
          <span class="absolute top-0 left-0 right-0 h-[3px] bg-primary [box-shadow:0_0_18px_var(--color-cms-red)]">
          </span>
          <p class="text-lg text-base-content leading-relaxed mb-6 max-w-[68ch]">
            {@copy.solution.description}
          </p>

          <div class="mt-6 grid gap-3.5">
            <%= for {item, i} <- Enum.with_index(@copy.solution.approach, 1) do %>
              <div class="flex gap-4 items-start py-3.5 px-4 border-l-2 border-primary bg-primary/[0.04]">
                <span class="font-mono text-[11px] uppercase tracking-[0.18em] text-primary font-bold w-[54px] flex-shrink-0 pt-1">
                  {String.pad_leading(Integer.to_string(i), 2, "0")}
                </span>
                <span class="text-base text-base-content leading-snug">{item}</span>
              </div>
            <% end %>
          </div>

          <div class="mt-8 pt-7 border-t border-primary/20 font-heading font-bold text-xl md:text-[28px] uppercase tracking-tight leading-snug">
            Stories<span class="text-primary mx-1.5">→</span>Architecture<span class="text-primary mx-1.5">→</span>BDD
            Specs<span class="text-primary mx-1.5">→</span>Impl<span class="text-primary mx-1.5">→</span>QA<span class="text-primary mx-1.5">→</span><span class="text-primary">
              Ship.
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── PHASES (stepper) ───
  defp phases_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 signal-top bg-[radial-gradient(ellipse_70%_60%_at_50%_0%,_rgba(255,56,56,0.05),_transparent_70%)]">
      <div class="max-w-7xl mx-auto px-6 py-24 lg:py-32">
        <.eyebrow idx="04" name="the_six_phases" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Each phase is <span class="text-primary">a real artifact.</span>
        </h2>

        <div class="mt-14 grid lg:grid-cols-[280px_1fr] gap-7 items-start">
          <%!-- step list (sidebar). Each tab sets --ac to its phase token;
               .method-tab utilities consume --ac for hover/active border + tab num color. --%>
          <div
            role="tablist"
            class="flex lg:flex-col gap-2 lg:sticky lg:top-20 overflow-x-auto lg:overflow-visible pb-2 lg:pb-0"
          >
            <%= for {phase, i} <- Enum.with_index(@copy.phases) do %>
              <button
                data-step={phase.number}
                style={"--ac: var(--color-cms-phase-#{phase.number});"}
                class={[
                  "step-tab method-tab font-mono text-[13px] text-left bg-transparent border border-base-300",
                  "text-base-content/70 px-4 py-3.5 cursor-pointer relative",
                  "flex items-center gap-3.5 chamfer-sm flex-shrink-0 min-w-[200px]",
                  if(i == 0, do: "is-active", else: "")
                ]}
              >
                <span class="method-tab-num font-heading font-bold text-lg w-6">
                  {String.pad_leading(Integer.to_string(phase.number), 2, "0")}
                </span>
                <span class="font-mono text-[13px] font-bold uppercase tracking-[0.06em]">
                  {phase.title}
                </span>
              </button>
            <% end %>
          </div>

          <%!-- step panels. Same --ac convention; .method-panel-* utilities
               consume it for the top bar, badge, tagline, bullets, and guide link. --%>
          <div>
            <%= for {phase, i} <- Enum.with_index(@copy.phases) do %>
              <div
                data-step={phase.number}
                style={"--ac: var(--color-cms-phase-#{phase.number}); #{if(i == 0, do: "", else: "display: none;")}"}
                class="step-panel bg-base-200 border border-base-300 chamfer-lg p-10 md:p-11 relative min-h-[440px]"
              >
                <span class="method-panel-bar"></span>

                <div class="flex justify-between items-center flex-wrap gap-3.5 font-mono text-[11px] uppercase tracking-[0.2em] text-base-content/50 mb-6 pb-5 border-b border-base-300">
                  <span>
                    phase {String.pad_leading(Integer.to_string(phase.number), 2, "0")} of 06
                  </span>
                  <span class="method-panel-badge px-2.5 py-1 chamfer-sm">
                    ▸ {String.downcase(phase.title)}
                  </span>
                </div>

                <h3 class="font-heading font-bold text-3xl md:text-[34px] uppercase tracking-tight mb-2">
                  {phase.title}
                </h3>
                <p class="method-panel-tagline font-mono text-sm mb-5">
                  <span class="text-base-content/50">// </span>{phase.tagline}
                </p>
                <p class="text-base text-base-content leading-[1.7] mb-7 max-w-[64ch]">
                  {phase.description}
                </p>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3.5 mb-7">
                  <%= for highlight <- phase.highlights do %>
                    <div class="method-panel-bullet flex gap-3 items-start font-body text-sm text-base-content/70 leading-snug py-2.5 px-3.5 bg-base-300">
                      <span class="method-panel-bullet-mark font-mono font-bold flex-shrink-0">
                        +
                      </span>
                      <span>{highlight}</span>
                    </div>
                  <% end %>
                </div>

                <div class="flex justify-between items-center flex-wrap gap-3.5 pt-5 border-t border-base-300">
                  <div class="font-mono text-[11px] text-base-content/70 uppercase tracking-[0.16em]">
                    creates
                    <span class="block mt-1 font-body text-[13px] text-base-content normal-case tracking-normal">
                      {phase.creates}
                    </span>
                  </div>
                  <.guide_link guide={phase.guide} />
                </div>
              </div>
            <% end %>

            <div class="mt-6 flex justify-between font-mono text-[11px] uppercase tracking-[0.18em]">
              <button
                id="mth-prev-step"
                disabled
                class="bg-transparent border border-base-300 text-base-content/70 px-4 py-2.5 cursor-pointer transition chamfer-sm enabled:hover:border-primary enabled:hover:text-primary disabled:opacity-30 disabled:cursor-not-allowed"
              >
                ← Prev
              </button>
              <button
                id="mth-next-step"
                class="bg-transparent border border-base-300 text-base-content/70 px-4 py-2.5 cursor-pointer transition chamfer-sm enabled:hover:border-primary enabled:hover:text-primary disabled:opacity-30 disabled:cursor-not-allowed"
              >
                Next →
              </button>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # ─── PROOF ───
  defp proof_section(assigns) do
    ~H"""
    <section class="border-b border-base-300 signal-top">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="05" name="the_proof" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight">
          Built with the loop. <span class="text-primary">Shipped with the loop.</span>
        </h2>

        <div class="mt-12 bg-base-200 border border-base-300 chamfer-lg p-10 md:p-11 relative">
          <span class="absolute top-0 left-0 w-full h-[2px] bg-primary"></span>
          <p class="text-[17px] text-base-content leading-relaxed mb-7 max-w-[64ch]">
            {@copy.proof.description}
          </p>

          <ul class="grid grid-cols-1 md:grid-cols-2 gap-3.5 list-none p-0 mb-8">
            <%= for item <- @copy.proof.evidence do %>
              <li class="font-body text-[14.5px] text-base-content leading-snug py-3 px-4 border-l-2 border-primary bg-primary/[0.04] flex gap-3 items-start">
                <span class="text-primary font-mono font-bold flex-shrink-0">✓</span>
                <span>{item}</span>
              </li>
            <% end %>
          </ul>

          <p class="pt-6 border-t border-base-300 font-mono text-sm text-base-content leading-snug">
            <span class="text-primary">// </span>{@copy.proof.tagline}
          </p>
        </div>
      </div>
    </section>
    """
  end

  # ─── CTA / Install ───
  defp cta_section(assigns) do
    ~H"""
    <section
      id="install"
      class="signal-top scanlines border-b border-base-300 bg-[radial-gradient(circle_at_75%_30%,_rgba(255,56,56,0.14),_transparent_55%),radial-gradient(circle_at_15%_80%,_rgba(255,56,56,0.06),_transparent_60%)]"
    >
      <div class="max-w-7xl mx-auto px-6 py-28 lg:py-32">
        <.eyebrow idx="06" name="start_the_loop" />
        <div class="mt-2 grid lg:grid-cols-[1.2fr_1fr] gap-12 items-center">
          <div>
            <h2 class="font-heading font-bold text-4xl md:text-6xl leading-[1.02] tracking-tight max-w-[14ch]">
              Run the loop on <span class="text-primary">your codebase.</span>
            </h2>
            <p class="text-lg text-base-content mt-6 max-w-[50ch] leading-relaxed">
              Phoenix-native today, ~30 minutes to set up. Install the plugin, run the story interview, and you're in phase 01.
            </p>
            <div class="mt-9 flex flex-wrap items-center gap-5">
              <a href={~p"/users/register"} class="btn btn-primary">▸ Try CodeMySpec</a>
              <a
                href={ExternalLinks.cal_john()}
                class="font-mono text-sm uppercase tracking-[0.14em] text-base-content border-b border-primary/30 hover:text-primary hover:border-primary transition pb-0.5"
              >
                Talk to John →
              </a>
            </div>
          </div>

          <.install_card
            harness="codemyspec"
            accent="red"
            brief_url={~p"/products/code-my-spec"}
            brief_label="brief →"
            footer_label="claude code · v1.0"
          />
        </div>
      </div>
    </section>
    """
  end

  # ─── FAQ ───
  defp faq_section(assigns) do
    ~H"""
    <section class="signal-top">
      <div class="max-w-3xl mx-auto px-6 py-24 lg:py-28">
        <.eyebrow idx="07" name="faq" />
        <h2 class="font-heading font-bold text-3xl md:text-5xl leading-[1.08] tracking-tight mb-3">
          Questions <span class="text-primary">we get.</span>
        </h2>

        <div class="mt-12 border-t border-primary/20">
          <%= for {item, i} <- Enum.with_index(@copy.faq) do %>
            <details class="border-b border-primary/20 group" open={i == 0}>
              <summary class="cursor-pointer list-none py-7 flex justify-between items-center gap-6 font-mono text-[15px] font-medium hover:text-primary transition">
                <span>
                  <span class="text-primary text-[11px] tracking-[0.22em] mr-3.5">
                    Q.{String.pad_leading(Integer.to_string(i + 1), 2, "0")}
                  </span>
                  {item.question}
                </span>
                <span class="font-mono text-sm text-primary border border-primary px-2 py-0.5 chamfer-sm transition group-open:bg-primary group-open:text-base-100 flex-shrink-0">
                  +
                </span>
              </summary>
              <div class="pb-7 text-base text-base-content/70 leading-relaxed max-w-[72ch]">
                {item.answer}
              </div>
            </details>
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
    <section
      class="signal-top border-t border-base-300 bg-[radial-gradient(circle_at_50%_50%,_rgba(255,56,56,0.10),_transparent_60%)]"
    >
      <div class="max-w-3xl mx-auto px-6 py-20 lg:py-24 text-center">
        <div class="mb-7 flex items-center justify-center gap-3 font-mono text-[11px] uppercase tracking-[0.22em] text-primary">
          <span class="h-px w-12 bg-gradient-to-r from-transparent to-primary"></span>
          <span>08 // ready</span>
          <span class="h-px w-12 bg-gradient-to-l from-transparent to-primary"></span>
        </div>
        <h2 class="font-heading font-bold text-3xl md:text-4xl leading-[1.08] tracking-tight max-w-[20ch] mx-auto">
          Now run the loop <span class="text-primary">on your codebase.</span>
        </h2>
        <p class="text-base text-base-content/70 mt-5 max-w-[48ch] mx-auto leading-relaxed">
          ~30 minutes to set up. One Claude Code plugin install. BYO model, BYO keys.
        </p>
        <div class="mt-9 flex flex-wrap justify-center items-center gap-5">
          <.link href={~p"/users/register"} class="btn btn-primary">
            ▸ Get started
          </.link>
          <a
            href="#install"
            class="font-mono text-sm uppercase tracking-[0.14em] text-base-content border-b border-primary/30 hover:text-primary hover:border-primary transition pb-0.5"
          >
            See install commands ↑
          </a>
        </div>
      </div>
    </section>
    """
  end

  # ─── Helpers ───
  attr :guide, :map, required: true

  defp guide_link(%{guide: %{status: :published}} = assigns) do
    ~H"""
    <a
      href={@guide.url}
      class="method-guide font-mono text-xs uppercase tracking-[0.14em] pb-0.5 transition"
    >
      {@guide.title} →
    </a>
    """
  end

  defp guide_link(%{guide: %{status: status}} = assigns)
       when status in [:draft, :planned] do
    ~H"""
    <span class="font-mono text-[11px] uppercase tracking-[0.14em] text-base-content/50 border border-base-300 px-2.5 py-1 chamfer-sm">
      Coming Soon
    </span>
    """
  end
end
