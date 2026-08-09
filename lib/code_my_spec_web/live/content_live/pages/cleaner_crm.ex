defmodule CodeMySpecWeb.ContentLive.Pages.CleanerCrm do
  @moduledoc """
  Case-study LiveView page for the Cleaner CRM build.

  Copy is inlined below; the stories fixture (21 stories with full Three
  Amigos records exported from the harness database) loads compile-time
  from the sibling `cleaner_crm_stories.exs`. Mirrors `MarketMySpec`,
  plus optional `bullets`/`close` keys on dev-story items and QA-attempt
  history badges in the stories modal.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @external_resource stories_path =
                       Path.join(__DIR__, "cleaner_crm_stories.exs")

  @stories (case Code.eval_file(stories_path) do
              {stories, _} -> stories
            end)

  @copy %{
    metadata: %{
      meta_title: "Cleaner CRM Case Study: Two Prompts, Three Days, Three Personas",
      meta_description:
        "How CodeMySpec built a full cleaning-business CRM from two prompts across three days in July 2026. 21 stories, 143 BDD spex, 331 tests, live Stripe, deployed UAT. Claude Fable 5 orchestrated; John typed 0.4% of the characters.",
      og_title: "Cleaner CRM Case Study — Two-Shotted With Fable",
      og_description:
        "A three-persona cleaning CRM built from two prompts plus two UAT passes. 21 stories, 143 BDD spex, 331 tests, real Stripe, live UAT. John typed 0.4% of the characters; Fable wrote the rest.",
      og_image: nil,
      author: "John Davenport",
      tags: [
        "case-study",
        "cleaner-crm",
        "phoenix",
        "elixir",
        "ai-development",
        "bdd",
        "harness-engineering",
        "auto-orchestration",
        "browser-qa",
        "three-amigos",
        "stripe"
      ]
    },
    hero: %{
      title: "Cleaner CRM",
      tagline: "Two prompts. Two UAT passes. Three days. Fable did the rest.",
      description:
        "A full cleaning-business CRM: owner back office, cleaner field app, and a public booking funnel with real Stripe payments, live on UAT. I two-shotted it: a 110-word prompt on July 7, one sentence for the customer side a day later. Claude Fable 5 orchestrated 172 subagents through the rest. Measured across the conversation, I typed 3,923 characters; the agent wrote just over a million.",
      stats: [
        %{label: "Prompts by John", value: "2"},
        %{label: "Stories Shipped", value: "21"},
        %{label: "BDD Criteria", value: "143"},
        %{label: "Characters Typed by John", value: "0.4%"}
      ]
    },
    overview: %{
      title: "What is Cleaner CRM?",
      description:
        "A Phoenix LiveView CRM for residential cleaning businesses, scoped by agent-run research into Jobber, Housecall Pro, and Maidily. Three personas: the owner runs the business, the cleaner works the day from a mobile field app, and the customer quotes, books, and pays without ever creating a password. Every story cites a research finding.",
      integrations: [
        %{
          name: "Stripe",
          description:
            "Payment Element card capture, card-on-file charges, payment links, signed webhooks with replay protection",
          icon: "hero-credit-card"
        },
        %{
          name: "Twilio",
          description: "SMS reminders with per-job failure isolation and email fallback",
          icon: "hero-device-phone-mobile"
        },
        %{
          name: "Resend",
          description: "Magic links, portal invitations, review requests",
          icon: "hero-envelope"
        },
        %{
          name: "Oban",
          description: "Reminder scans, review scheduling, recurring-visit materialization",
          icon: "hero-clock"
        },
        %{
          name: "Kamal + Hetzner",
          description: "Health-checked container swaps, SSM-bootstrapped secrets",
          icon: "hero-server"
        },
        %{
          name: "Wallaby",
          description: "Five headless-Chrome journey tests codifying the QA runs",
          icon: "hero-window"
        }
      ],
      key_features: [
        "Recurring plans with series-wide conflict detection and per-visit overrides",
        "Weekly dispatch board with reassignment and acknowledged schedule-change alerts",
        "Quotes and invoicing off an owner-configured rate card, Stripe card-on-file",
        "Public instant-quote calculator and online booking at /book, no login required",
        "Magic-link client portal: proof-of-work photos, policy-gated reschedule, pay and tip",
        "Cleaner field app: day view, room-by-room checklists with photo proof, live earnings",
        "Timesheets with hourly and piece-rate pay, payroll CSV export",
        "Photo-proof quality scorecards, review engine, append-only audit trail",
        "Role-gated routing: cleaners physically cannot reach office data"
      ]
    },
    repository: %{
      title: "Open Source Repository",
      description:
        "The repo is public, full build transcripts included: 194 raw session files under .code_my_spec/conversations, synced by a pre-commit hook. Every failure in this teardown is in there. This case study was mined from those transcripts.",
      url: "https://github.com/Code-My-Spec/cleaner_crm",
      stats: [
        %{label: "Language", value: "Elixir / Phoenix"},
        %{label: "Tests", value: "331 (0 failures)"},
        %{label: "Wallaby Journeys", value: "5"},
        %{label: "Transcripts Committed", value: "194 files"}
      ]
    },
    dev_story: %{
      title: "The Dev Story",
      subtitle: "The Good, The Bad, and The Ugly",
      description:
        "One 110-word prompt to a green BDD suite in 4 hours 12 minutes. Overnight, browser QA filed 35 issues and dispatched its own fixers while I slept. Day two: I spotted the missing customer persona at demo time and commissioned it in one sentence. Day three: live UAT, real Stripe, and a stranger from Reddit stress-testing it. Plenty broke along the way.",
      sections: [
        %{
          id: "good",
          label: "The Good",
          icon: "hero-check-circle",
          color: "success",
          items: [
            "110-word prompt to a green BDD suite in 4h12m: research, 2 personas, 15 stories, ~100 spex, 146 tests",
            "Research agents corrected my own brief: the competitor I named does not exist; they identified the real one",
            "Browser QA ran itself: 35 issues filed, fixed, and re-verified agent to agent; a critical authz hole fixed in 8 minutes",
            "QA caught what specs could not: a dropdown that no-opped in real browsers, a cleaner who could export the company's payroll, a booking dated 2020",
            "The missing customer side went from one sentence to a QA'd public booking funnel in 2.5 hours",
            "The real Stripe sandbox caught a Live-adapter bug on the first charge; cassette tests caught a webhook replay vulnerability",
            "Guardrails held: agents escalated instead of routing around permission blocks, and confessed their own messes unprompted",
            "Fable orchestrated 172 subagents; I typed 0.4% of the characters (3,923 vs 1,027,791)"
          ]
        },
        %{
          id: "bad",
          label: "The Bad",
          icon: "hero-exclamation-triangle",
          color: "warning",
          items: [
            "Specs have bugs too: six defect classes on day one, including a story reading 0/5 against a fully correct implementation",
            "Parallel agents collided on everything shared: one browser, one dev server (9+ restarts), one Postgres, one migration timeline",
            "Features shipped without their admin half, twice: rate card and cancellation policy configurable only via psql",
            "The same past-date bug shipped in two code paths; nothing asks where else a just-fixed bug class lives",
            "Harness gates cried wolf: stop hooks firing on the wrong sessions, stale-warning demands, wakeups after the mission ended"
          ]
        },
        %{
          id: "ugly",
          label: "The Ugly",
          icon: "hero-fire",
          color: "error",
          items: [
            "The build declared itself done with an entire persona missing. My prompt specified two, so it built two; the demo review is the gate no requirement graph replaces",
            "The harness's own MCP server went down for 8.5 hours; verified QA work sat unsubmittable while the app stayed green",
            "False-positive green: three features passed every spec while broken in every real browser. LiveView test helpers drive the server, not the browser",
            "A stranger from Reddit broke it in ten minutes: a $0.12 cleaning, a Fartmail email, a 4,000-hour booking. Report to deployed fixes in 51 minutes",
            "The dev environment melted down under multi-agent load; the agent abandoned dev-mode serving and invented an immutable-release QA pattern mid-run"
          ]
        }
      ]
    },
    conclusion: %{
      closing:
        "Three days. Two prompts: 110 words to start, one sentence for the customer side. Twenty-one stories across three personas, 143 BDD spex, 331 tests, real Stripe payments, and a live UAT. Two UAT passes, one donated by a stranger on Reddit. I typed 0.4 percent of the characters; Claude Fable 5 orchestrated 172 subagents through the rest. That's the loop that ships."
    }
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing current_path={assigns[:current_path]} flash={@flash} current_scope={@current_scope}>
      {hero_section(assigns)}
      {overview_section(assigns)}
      {stories_section(assigns)}
      {repository_section(assigns)}
      {dev_story_section(assigns)}
      {conclusion_section(assigns)}

      <.stories_modal :if={@show_stories_modal} stories={@stories} />
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    stories = @stories
    base_url = CodeMySpecWeb.Endpoint.url()

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "Article",
          "@id" => "#{base_url}/case-studies/cleaner-crm",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/case-studies/cleaner-crm",
          "image" => %{
            "@type" => "ImageObject",
            "url" => CodeMySpecWeb.ImageUrl.image_url("og-cleanercrm.png", base_url),
            "width" => 1200,
            "height" => 630
          },
          "datePublished" => "2026-07-10T00:00:00Z",
          "dateModified" => "2026-07-10T00:00:00Z",
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
            "@id" => "#{base_url}/case-studies/cleaner-crm"
          },
          "articleSection" => "Case Studies"
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
            },
            %{
              "@type" => "ListItem",
              "position" => 3,
              "name" => "Cleaner CRM",
              "item" => "#{base_url}/case-studies/cleaner-crm"
            }
          ]
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:stories, stories)
     |> assign(:show_stories_modal, false)
     |> assign(:active_tab, "good")
     |> assign(:canonical_url, "#{base_url}/case-studies/cleaner-crm")
     |> assign(:og_image, CodeMySpecWeb.ImageUrl.image_url("og-cleanercrm.png", base_url))
     |> assign(:og_type, "article")
     |> assign(:article_published_time, "2026-07-10T00:00:00Z")
     |> assign(:json_ld, json_ld)}
  end

  @impl true
  def handle_event("open_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, true)}
  end

  def handle_event("close_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, false)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  defp hero_section(assigns) do
    ~H"""
    <div class="hero mb-16">
      <div class="hero-content text-center">
        <div class="max-w-4xl">
          <div class="badge badge-primary badge-lg mb-4">Case Study</div>
          <h1 class="text-5xl md:text-6xl font-extrabold mb-4 bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
            {@copy.hero.title}
          </h1>
          <p class="text-2xl md:text-3xl font-bold mb-4 text-base-content">
            {@copy.hero.tagline}
          </p>
          <p class="text-xl mb-10 text-base-content/70 max-w-2xl mx-auto">
            {@copy.hero.description}
          </p>

          <div class="stats stats-horizontal bg-base-100 shadow border border-base-300">
            <%= for stat <- @copy.hero.stats do %>
              <div class="stat px-8 py-4">
                <div class="stat-value text-primary text-2xl">{stat.value}</div>
                <div class="stat-desc text-base-content/60 text-sm">{stat.label}</div>
              </div>
            <% end %>
          </div>

          <div class="mt-8 flex flex-wrap justify-center gap-3">
            <a href="/methodology" class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the Full Methodology
            </a>
            <a
              :if={@copy.repository.url}
              href={@copy.repository.url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-outline btn-lg gap-2"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5" /> View on GitHub
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp overview_section(assigns) do
    ~H"""
    <div class="mb-16" id="overview">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-4">{@copy.overview.title}</h2>
        <p class="text-xl text-base-content/70 max-w-3xl mx-auto">
          {@copy.overview.description}
        </p>
      </div>

      <div class="flex flex-wrap justify-center gap-6 mb-10">
        <%= for integration <- @copy.overview.integrations do %>
          <div class="card bg-base-100 shadow-lg border border-base-300 hover:shadow-xl transition-shadow w-48">
            <div class="card-body items-center text-center p-5">
              <.icon name={integration.icon} class="w-10 h-10 text-primary mb-2" />
              <h3 class="font-bold text-sm">{integration.name}</h3>
              <p class="text-xs text-base-content/60">{integration.description}</p>
            </div>
          </div>
        <% end %>
      </div>

      <div class="card bg-base-100 shadow-lg border border-base-300 max-w-3xl mx-auto">
        <div class="card-body">
          <h3 class="card-title text-lg mb-3">
            <.icon name="hero-list-bullet" class="w-5 h-5 text-primary" /> Key Features
          </h3>
          <ul class="space-y-2">
            <%= for feature <- @copy.overview.key_features do %>
              <li class="flex items-start gap-3">
                <.icon
                  name="hero-check-circle-solid"
                  class="w-5 h-5 text-success flex-shrink-0 mt-0.5"
                />
                <span class="text-base-content/80">{feature}</span>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp stories_section(assigns) do
    total_criteria = Enum.reduce(assigns.stories, 0, fn s, acc -> acc + length(s.criteria) end)

    three_amigos_stories =
      Enum.count(assigns.stories, fn s -> Map.get(s, :three_amigos) != nil end)

    assigns =
      assigns
      |> assign(:total_criteria, total_criteria)
      |> assign(:three_amigos_stories, three_amigos_stories)

    ~H"""
    <div class="mb-16" id="stories">
      <div class="card bg-base-100 shadow-xl border border-base-300 max-w-3xl mx-auto">
        <div class="card-body p-8 text-center">
          <h2 class="text-3xl font-bold mb-4">
            <.icon name="hero-clipboard-document-list" class="w-8 h-8 text-primary inline" />
            User Stories
          </h2>
          <p class="text-base-content/70 mb-6">
            Every story that drove this build, complete and unexcerpted: persona, Three Amigos rules with full given-when-then scenarios, acceptance criteria, and resolved questions, exported straight from the harness database. All 21 passed browser-level QA.
          </p>

          <div class="stats bg-base-200 shadow mb-6">
            <div class="stat">
              <div class="stat-value text-primary">{length(@stories)}</div>
              <div class="stat-desc">Stories</div>
            </div>
            <div class="stat">
              <div class="stat-value text-secondary">{@total_criteria}</div>
              <div class="stat-desc">Acceptance Criteria</div>
            </div>
            <div class="stat">
              <div class="stat-value text-accent">{@three_amigos_stories}</div>
              <div class="stat-desc">With Three Amigos</div>
            </div>
          </div>

          <button class="btn btn-primary btn-lg gap-2" phx-click="open_stories">
            <.icon name="hero-book-open" class="w-5 h-5" /> Browse Stories &amp; Three Amigos
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp repository_section(assigns) do
    ~H"""
    <div class="mb-16" id="repository">
      <div class="card bg-gradient-to-br from-base-200 to-base-100 shadow-xl border border-base-300 max-w-3xl mx-auto">
        <div class="card-body p-6 lg:p-8">
          <div class="flex flex-col sm:flex-row items-start sm:items-center gap-6">
            <div class="flex-1">
              <h2 class="text-2xl font-bold mb-2 flex items-center gap-2">
                <.icon name="hero-code-bracket" class="w-6 h-6 text-primary" />
                {@copy.repository.title}
              </h2>
              <p class="text-base text-base-content/70 mb-4">{@copy.repository.description}</p>
              <a
                :if={@copy.repository.url}
                href={@copy.repository.url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-primary btn-sm gap-2"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View on GitHub
              </a>
            </div>
            <div class="grid grid-cols-2 gap-2 flex-shrink-0">
              <%= for stat <- @copy.repository.stats do %>
                <div class="bg-base-100 rounded-box px-3 py-2 text-center border border-base-300">
                  <div class="text-xs font-bold text-primary">{stat.value}</div>
                  <div class="text-[10px] text-base-content/50 leading-tight">{stat.label}</div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp dev_story_section(assigns) do
    ~H"""
    <div class="mb-16" id="dev-story">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-2">{@copy.dev_story.title}</h2>
        <p class="text-2xl font-semibold text-base-content/80 mb-4">{@copy.dev_story.subtitle}</p>
        <p class="text-lg text-base-content/60 max-w-3xl mx-auto">
          {@copy.dev_story.description}
        </p>
      </div>

      <div class="max-w-4xl mx-auto">
        <div role="tablist" class="tabs tabs-boxed bg-base-200 mb-6 p-1">
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "good", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="good"
          >
            <.icon name="hero-check-circle" class="w-4 h-4" /> The Good
          </button>
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "bad", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="bad"
          >
            <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> The Bad
          </button>
          <button
            role="tab"
            class={"tab gap-2 #{if @active_tab == "ugly", do: "tab-active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab="ugly"
          >
            <.icon name="hero-fire" class="w-4 h-4" /> The Ugly
          </button>
        </div>

        <%= for section <- @copy.dev_story.sections do %>
          <div class={if @active_tab == section.id, do: "", else: "hidden"}>
            <div class={dev_story_card_class(section.id)}>
              <div class="card-body">
                <ul class="space-y-3">
                  <%= for item <- section.items do %>
                    <li class="flex items-start gap-3">
                      <.icon
                        name={section.icon}
                        class={"w-5 h-5 flex-shrink-0 mt-0.5 #{dev_story_title_class(section.id)}"}
                      />
                      <span class="text-base-content/80">{item}</span>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp conclusion_section(assigns) do
    ~H"""
    <div class="mb-16" id="conclusion">
      <div class="card bg-gradient-to-r from-primary/10 to-secondary/10 border border-primary/20 shadow-xl max-w-3xl mx-auto">
        <div class="card-body text-center">
          <p class="text-lg text-base-content/80">{@copy.conclusion.closing}</p>
          <div class="card-actions justify-center mt-4">
            <a href="/methodology" class="btn btn-primary gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the Full Methodology
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp dev_story_card_class("good"), do: "card bg-success/5 border border-success/20 shadow"
  defp dev_story_card_class("bad"), do: "card bg-warning/5 border border-warning/20 shadow"
  defp dev_story_card_class("ugly"), do: "card bg-error/5 border border-error/20 shadow"

  defp dev_story_title_class("good"), do: "text-success"
  defp dev_story_title_class("bad"), do: "text-warning"
  defp dev_story_title_class("ugly"), do: "text-error"

  defp story_status_badge(%{status: :completed} = assigns) do
    ~H"""
    <div class="badge badge-success badge-sm gap-1">
      <.icon name="hero-check" class="w-3 h-3" /> Done
    </div>
    """
  end

  defp story_status_badge(%{status: :in_progress} = assigns) do
    ~H"""
    <div class="badge badge-info badge-sm gap-1">
      <.icon name="hero-arrow-path" class="w-3 h-3" /> In Progress
    </div>
    """
  end

  defp story_status_badge(assigns) do
    ~H"""
    <div class="badge badge-ghost badge-sm">New</div>
    """
  end

  attr :stories, :list, required: true

  defp stories_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl max-h-[85vh]">
        <div class="flex items-center justify-between mb-6 sticky top-0 bg-base-100 pb-4 z-10 border-b border-base-300">
          <h3 class="font-bold text-2xl">
            <.icon name="hero-clipboard-document-list" class="w-6 h-6 text-primary inline" />
            Cleaner CRM Stories ({length(@stories)})
          </h3>
          <button class="btn btn-sm btn-circle btn-ghost" phx-click="close_stories">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div class="space-y-3 overflow-y-auto">
          <%= for story <- @stories do %>
            <div class="collapse collapse-arrow bg-base-200 border border-base-300">
              <input type="checkbox" />
              <div class="collapse-title">
                <div class="flex items-center justify-between pr-4">
                  <div class="flex-1">
                    <span class="font-semibold text-base">
                      <span class="text-base-content/40 mr-2">#{story.story_id}</span>{story.title}
                    </span>
                  </div>
                  <div class="flex items-center gap-2 ml-4 flex-shrink-0">
                    <%= if Map.get(story, :three_amigos) do %>
                      <div class="badge badge-accent badge-sm gap-1">
                        <.icon name="hero-users" class="w-3 h-3" /> 3A
                      </div>
                    <% end %>
                    <.story_status_badge status={story.status} />
                    <div class="badge badge-outline badge-sm gap-1">
                      <.icon name="hero-clipboard-document-check" class="w-3 h-3" />
                      {length(story.criteria)}
                    </div>
                  </div>
                </div>
              </div>
              <div class="collapse-content">
                <p class="text-base-content/80 mb-4 leading-relaxed">
                  {story.description}
                </p>

                <div :if={story.tags != []} class="mb-4 flex flex-wrap gap-1">
                  <span :for={tag <- story.tags} class="badge badge-sm badge-outline">
                    {tag.name}
                  </span>
                </div>

                <%= if Map.get(story, :qa) do %>
                  <div class="mb-4 flex items-center gap-2 flex-wrap">
                    <span class="text-xs font-semibold text-base-content/60">Browser QA:</span>
                    <span :for={attempt <- story.qa.history} class={qa_badge_class(attempt)}>
                      {attempt}
                    </span>
                  </div>
                <% end %>

                <%= if story.criteria != [] do %>
                  <h4 class="font-semibold mb-2 text-sm">Acceptance Criteria:</h4>
                  <ul class="space-y-1.5 text-base-content/80 mb-4">
                    <%= for criterion <- story.criteria do %>
                      <li class="flex items-center gap-2 text-sm">
                        <.icon
                          :if={criterion.verified}
                          name="hero-lock-closed"
                          class="size-3 text-success inline flex-shrink-0"
                        />
                        <.icon
                          :if={!criterion.verified}
                          name="hero-minus-circle"
                          class="size-3 text-base-content/30 inline flex-shrink-0"
                        />
                        <span class={[criterion.verified && "font-medium"]}>
                          {criterion.description}
                        </span>
                      </li>
                    <% end %>
                  </ul>
                <% end %>

                <%= if Map.get(story, :three_amigos) do %>
                  <.three_amigos_block three_amigos={story.three_amigos} />
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_stories"></div>
    </div>
    """
  end

  attr :three_amigos, :map, required: true

  defp three_amigos_block(assigns) do
    ~H"""
    <div class="mt-4 pt-4 border-t border-base-300">
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm flex items-center gap-2">
          <.icon name="hero-users" class="w-4 h-4 text-accent" /> Three Amigos Records
        </h4>
      </div>

      <div :if={@three_amigos.persona} class="card bg-base-100 border border-base-300 mb-3">
        <div class="card-body p-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.icon name="hero-user-circle" class="w-5 h-5 text-primary" />
              <span class="font-semibold text-sm">{@three_amigos.persona.name}</span>
              <span class="text-xs text-base-content/50">@{@three_amigos.persona.slug}</span>
            </div>
            <span class="badge badge-outline badge-xs">{@three_amigos.persona.type}</span>
          </div>
        </div>
      </div>

      <div :if={@three_amigos.rules != []} class="mb-3">
        <h5 class="text-sm font-semibold text-base-content/70 mb-2">
          Rules &amp; Scenarios
        </h5>
        <div class="space-y-2">
          <%= for {rule, idx} <- Enum.with_index(@three_amigos.rules, 1) do %>
            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-3">
                <div class="flex gap-2 items-start">
                  <span class="badge badge-info badge-sm flex-shrink-0">R{idx}</span>
                  <span class="text-sm leading-relaxed">{rule.statement}</span>
                </div>

                <div :if={rule.scenarios != []} class="mt-3 ml-6 space-y-2">
                  <%= for scenario <- rule.scenarios do %>
                    <div class="bg-base-200 rounded p-2 border-l-2 border-accent">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="badge badge-accent badge-xs">{scenario.kind}</span>
                        <span class="text-xs font-medium">{scenario.title}</span>
                      </div>
                      <pre
                        :if={scenario.body}
                        class="text-xs whitespace-pre-wrap text-base-content/80 mt-1 font-mono leading-relaxed"
                      >{scenario.body}</pre>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div :if={@three_amigos.questions != []} class="mb-3">
        <h5 class="text-sm font-semibold text-base-content/70 mb-2">
          Questions
        </h5>
        <div class="space-y-2">
          <%= for {question, idx} <- Enum.with_index(@three_amigos.questions, 1) do %>
            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-3">
                <div class="flex gap-2 items-start mb-2">
                  <span class="badge badge-warning badge-sm flex-shrink-0">Q{idx}</span>
                  <span class="text-sm leading-relaxed flex-1">{question.body}</span>
                  <span class={"badge badge-xs flex-shrink-0 #{question_status_class(question.status)}"}>
                    {question.status}
                  </span>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp qa_badge_class("pass"), do: "badge badge-success badge-xs"
  defp qa_badge_class("fail"), do: "badge badge-error badge-xs"
  defp qa_badge_class("partial"), do: "badge badge-warning badge-xs"
  defp qa_badge_class(atom) when is_atom(atom), do: qa_badge_class(Atom.to_string(atom))
  defp qa_badge_class(_), do: "badge badge-ghost badge-xs"

  defp question_status_class(:resolved), do: "badge-success"
  defp question_status_class(:open), do: "badge-warning"
  defp question_status_class(_), do: "badge-ghost"
end
