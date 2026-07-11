defmodule CodeMySpecWeb.ContentLive.Pages.CaseStudiesIndex do
  @moduledoc """
  Index page for the case-studies collection.

  Hard-coded list matching the static LiveView pages at
  `/case-studies/metric-flow`, `/case-studies/market-my-spec`, and
  `/case-studies/cleaner-crm`. Resolves the breadcrumb parent that
  the detail pages reference.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @case_studies [
    %{
      slug: "legwork",
      title: "Legwork",
      tagline:
        "My manual outbound process, productized in a weekend. The agent is one of the users.",
      summary:
        "An outbound-process composer built with Claude Opus 4.8 over one weekend (July 5-6, 2026). Five-stage prose runbooks an LLM agent works via 16 OAuth-authenticated MCP tools, with a human launch gate. Gating John's real prospects on day two, overturning his own guesses 8 times out of 12.",
      og_image: "og-legwork.png",
      stats: [
        %{label: "Build Time", value: "1 weekend"},
        %{label: "Stories", value: "7"},
        %{label: "Typed by John", value: "2.1%"}
      ],
      published_at: "2026-07-11"
    },
    %{
      slug: "keel",
      title: "Keel",
      tagline: "My own books. 9,225 transactions. The agent found $227,736 of phantom income.",
      summary:
        "An agent-first, double-entry, cross-border personal-finance ledger John built on his real books over 26 days (June 15 to July 10, 2026). The collaborative end of the dial: 2.9% of the conversation typed by the human, who supplied the accounting judgment no fixture could encode.",
      og_image: "og-keel.png",
      stats: [
        %{label: "Phantom Income Found", value: "$227,736"},
        %{label: "Stories", value: "48"},
        %{label: "Typed by John", value: "2.9%"}
      ],
      published_at: "2026-07-11"
    },
    %{
      slug: "cleaner-crm",
      title: "Cleaner CRM",
      tagline: "Two prompts. Two UAT passes. Three days. Fable did the rest.",
      summary:
        "A full cleaning-business CRM two-shotted with Claude Fable 5 (July 7-9, 2026). Owner back office, cleaner field app, public booking funnel with real Stripe payments, deployed to live UAT. 172 subagents, 0.4% of the conversation typed by John, and an honest accounting of everything that broke.",
      og_image: "og-cleanercrm.png",
      stats: [
        %{label: "Prompts by John", value: "2"},
        %{label: "Stories", value: "21"},
        %{label: "Typed by John", value: "0.4%"}
      ],
      published_at: "2026-07-10"
    },
    %{
      slug: "market-my-spec",
      title: "Market My Spec",
      tagline: "Zero prompts. Zero lines of code. Four days. Same harness.",
      summary:
        "A small MCP server built by CodeMySpec across one weekend (May 3-6, 2026). Configurable per-component workflow, Three Amigos as a real agent task, BDD-spec boundary protection. The honest teardown of the experiments that made zero-prompts possible.",
      og_image: "og-marketmyspec.png",
      stats: [
        %{label: "Build Days", value: "4"},
        %{label: "Stories", value: "13"},
        %{label: "Prompts by John", value: "0"}
      ],
      published_at: "2026-05-07"
    },
    %{
      slug: "metric-flow",
      title: "MetricFlow",
      tagline: "The harness wrote the code. Here's what worked and what didn't.",
      summary:
        "A Phoenix LiveView marketing analytics platform built by CodeMySpec in 13 working days. OAuth integrations across five platforms, multi-tenant accounts with agency white-labeling, correlation analysis, AI insights. The first end-to-end teardown.",
      og_image: "og-metricflow.png",
      stats: [
        %{label: "Working Days", value: "13"},
        %{label: "Stories", value: "51"},
        %{label: "Acceptance Criteria", value: "434"}
      ],
      published_at: "2026-03-20"
    }
  ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div class="hero mb-12">
        <div class="hero-content text-center">
          <div class="max-w-3xl">
            <div class="badge badge-primary badge-lg mb-4">Case Studies</div>
            <h1 class="text-5xl md:text-6xl font-extrabold mb-4 bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
              What the harness has shipped
            </h1>
            <p class="text-xl text-base-content/70">
              End-to-end teardowns of products built with CodeMySpec. The code, the specs, the failure modes, and what changed in the harness as a result.
            </p>
          </div>
        </div>
      </div>

      <div class="max-w-5xl mx-auto space-y-6 mb-16">
        <%= for cs <- @case_studies do %>
          <a
            href={"/case-studies/#{cs.slug}"}
            class="card lg:card-side bg-base-100 shadow-xl border border-base-300 hover:shadow-2xl transition-shadow group"
          >
            <figure class="lg:w-2/5 bg-[#191813]">
              <img
                src={CodeMySpecWeb.ImageUrl.image_url(cs.og_image, CodeMySpecWeb.Endpoint.url())}
                alt={"#{cs.title} case study preview"}
                class="w-full h-full"
                style="object-fit: contain; filter: none;"
                loading="lazy"
              />
            </figure>
            <div class="card-body lg:w-3/5">
              <h2 class="card-title text-3xl group-hover:text-primary transition-colors">
                {cs.title}
              </h2>
              <p class="text-lg font-semibold text-base-content/80">{cs.tagline}</p>
              <p class="text-base-content/70">{cs.summary}</p>

              <div class="stats stats-horizontal bg-base-200 shadow mt-2">
                <%= for stat <- cs.stats do %>
                  <div class="stat px-4 py-3">
                    <div class="stat-value text-primary text-xl">{stat.value}</div>
                    <div class="stat-desc text-base-content/60 text-xs">{stat.label}</div>
                  </div>
                <% end %>
              </div>

              <div class="card-actions justify-end mt-2">
                <span class="btn btn-primary btn-sm gap-2">
                  Read the teardown <.icon name="hero-arrow-right" class="w-4 h-4" />
                </span>
              </div>
            </div>
          </a>
        <% end %>
      </div>

      <div class="card bg-gradient-to-r from-primary/10 to-secondary/10 border border-primary/20 shadow-xl max-w-3xl mx-auto mb-16">
        <div class="card-body text-center">
          <h2 class="card-title text-2xl justify-center">Want the methodology behind these?</h2>
          <p class="text-base-content/80">
            The case studies are the receipts. The methodology is the process that produced them.
          </p>
          <div class="card-actions justify-center mt-2">
            <a href="/methodology" class="btn btn-primary gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the Full Methodology
            </a>
          </div>
        </div>
      </div>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    base_url = CodeMySpecWeb.Endpoint.url()
    case_studies = @case_studies

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "CollectionPage",
          "@id" => "#{base_url}/case-studies",
          "name" => "Case Studies",
          "description" =>
            "End-to-end teardowns of products built with CodeMySpec. Honest assessments of what worked, what broke, and what changed in the harness.",
          "url" => "#{base_url}/case-studies",
          "mainEntity" => %{
            "@type" => "ItemList",
            "itemListElement" =>
              case_studies
              |> Enum.with_index(1)
              |> Enum.map(fn {cs, idx} ->
                %{
                  "@type" => "ListItem",
                  "position" => idx,
                  "url" => "#{base_url}/case-studies/#{cs.slug}",
                  "name" => cs.title
                }
              end)
          }
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{
              "@type" => "ListItem",
              "position" => 2,
              "name" => "Case Studies",
              "item" => "#{base_url}/case-studies"
            }
          ]
        }
      ])

    {:ok,
     socket
     |> assign(:case_studies, case_studies)
     |> assign(:meta_title, "Case Studies — CodeMySpec")
     |> assign(
       :meta_description,
       "End-to-end teardowns of products built with CodeMySpec. MetricFlow, Market My Spec, Cleaner CRM, and the harness changes each one drove."
     )
     |> assign(:og_title, "Case Studies — CodeMySpec")
     |> assign(
       :og_description,
       "End-to-end teardowns of products built with CodeMySpec. The honest case studies."
     )
     |> assign(:canonical_url, "#{base_url}/case-studies")
     |> assign(
       :og_image,
       CodeMySpecWeb.ImageUrl.image_url("og-marketmyspec.png", base_url)
     )
     |> assign(:og_type, "website")
     |> assign(:json_ld, json_ld)}
  end
end
