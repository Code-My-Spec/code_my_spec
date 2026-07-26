defmodule CodeMySpecWeb.ContentLive.Pages.Keel do
  @moduledoc """
  Case-study LiveView page for the Keel build.

  Copy is inlined below; the stories fixture (48 stories with full Three
  Amigos records exported from the harness database) loads compile-time
  from the sibling `keel_stories.exs`. Mirrors `CleanerCrm`. QA badges
  render only for the 12 stories that ran browser QA; statuses are the
  honest harness state, not blanket-completed.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @external_resource stories_path =
                       Path.join(__DIR__, "keel_stories.exs")

  @stories (case Code.eval_file(stories_path) do
              {stories, _} -> stories
            end)

  @copy %{
    metadata: %{
      meta_title: "Keel Case Study: The Agent Found $227,736 of Phantom Income",
      meta_description:
        "John built an agent-first, double-entry, cross-border ledger for his own books with CodeMySpec over 26 days. 48 stories, 182 BDD criteria, 9,225 real transactions. He typed 2.9% of the characters; the agent found $227k of income Quicken had miscounted.",
      og_title: "Keel Case Study — My Books, The Agent's Labor",
      og_description:
        "An agent-first double-entry ledger built on John's real cross-border finances. 9,225 transactions balancing to the cent, $227,736 of phantom income found, 2.9% of the conversation typed by the human. The honest teardown of the collaborative build.",
      og_image: nil,
      author: "John Davenport",
      tags: [
        "case-study",
        "keel",
        "phoenix",
        "elixir",
        "ai-development",
        "bdd",
        "double-entry",
        "personal-finance",
        "mcp",
        "human-in-the-loop",
        "three-amigos"
      ]
    },
    hero: %{
      title: "Keel",
      tagline: "My own books. 9,225 transactions. The agent found $227,736 of phantom income.",
      description:
        "An agent-first, multi-currency, double-entry ledger I built because I hate Quicken and Firefly III's UI defeated me. Built with the harness over 26 days on my real cross-border finances, as my daily driver. This is the other end of the dial from Cleaner CRM: there the split measured 0.4% human; here it measured 2.9%, because on your own money you are the oracle. The agent did the labor. I supplied the judgment.",
      stats: [
        %{label: "Phantom Income Found", value: "$227,736"},
        %{label: "Stories", value: "48"},
        %{label: "BDD Criteria", value: "182"},
        %{label: "Typed by John", value: "2.9%"}
      ]
    },
    overview: %{
      title: "What is Keel?",
      description:
        "A double-entry ledger you talk to. Point it at your financial history and the agent proposes categorization rules, hunts down mystery transactions, reconciles transfers, and traces where money went, instead of you clicking through thousands of rows. Cross-border by design: per-currency balances, real FX, two entities, one set of books. Two personas drove the stories: the cross-border owner-operator, and the Keel Categorization Agent, an AI persona with stories of its own.",
      integrations: [
        %{
          name: "Quicken",
          description:
            "Direct import from Quicken's internal SQLite: raw bank descriptions, native transfer links, real account types",
          icon: "hero-circle-stack"
        },
        %{
          name: "Bank of Canada",
          description:
            "Daily FX rates via the Valet API, cassette-recorded against the real service",
          icon: "hero-globe-alt"
        },
        %{
          name: "MCP (anubis)",
          description:
            "22 intent-level tools, zero CRUD: post, propose, preview, trace. Deleting is refused",
          icon: "hero-command-line"
        },
        %{
          name: "Coinbase",
          description:
            "Crypto history as asset-as-currency on the same FX engine, ACB cost basis",
          icon: "hero-currency-dollar"
        },
        %{
          name: "Postgres",
          description:
            "A deferred sum-to-zero trigger: unbalanced transactions cannot commit, by construction",
          icon: "hero-shield-check"
        },
        %{
          name: "ex_money",
          description:
            "Money as money: no floats, no cross-currency sums, custom crypto currencies",
          icon: "hero-calculator"
        }
      ],
      key_features: [
        "Append-only double-entry core: corrections are reversing entries, the DB rejects unbalanced posts",
        "Deterministic rules engine first; the LLM only ever sees the unmatched tail",
        "Two-sided transfer rules: keyed exact matches, fuzzy proposals, remainder accounts that split a mortgage payment into principal and interest",
        "Classification workbench: cluster the uncategorized tail, preview a rule against real data, approve, hundreds of rows clear",
        "Multi-currency done right: per-currency balances, 4-leg FX transactions, never a cross-currency sum",
        "Idempotent re-import: wipe and rebuild from Quicken any time, rules and links survive",
        "Crypto holdings as currencies: Buys, Converts, Sells, and staking rewards on the existing FX machinery",
        "Tags and forward money-tracing: ask where a wire went and get the full chain, hop by hop",
        "Reports that reproduced Quicken's own P&L to the cent, then caught it double-counting"
      ]
    },
    repository: %{
      title: "Open Source Repository",
      description:
        "Keel is public in the Code-My-Spec org. Unlike Cleaner CRM, the build transcripts stay private: they are 53MB of me discussing my actual finances with an agent. Every number in this teardown is one I approved for the public demo.",
      url: "https://github.com/Code-My-Spec/keel",
      stats: [
        %{label: "Language", value: "Elixir / Phoenix"},
        %{label: "BDD Spex", value: "167 green"},
        %{label: "Unit Tests", value: "119"},
        %{label: "MCP Tools", value: "22"}
      ]
    },
    dev_story: %{
      title: "The Dev Story",
      subtitle: "The Good, The Bad, and The Ugly",
      description:
        "Cleaner CRM measured what autonomy looks like: 0.4% human. Keel measured the collaborative end: 2.9%, 300 messages across 26 days, because this is my money and I am the oracle. The agent wrote 2.86 million characters and did all the labor. I supplied product decisions, accounting judgment, and the one failing test no fixture could encode: my own memory of my own finances.",
      sections: [
        %{
          id: "good",
          label: "The Good",
          icon: "hero-check-circle",
          color: "success",
          items: [
            "One evening from empty repo to build-ready: personas, 37 stories, 11 ADRs, a validated architecture, Three Amigos on 14 stories, 48 BDD specs",
            "8,082 transactions of nine years of Quicken history posted as balanced double-entry in 6.7 seconds, 12 of 12 accounts reconciling to the cent",
            "Keel out-audited Quicken within four days: caught its own report double-counting transactions and mislabeling a 401(k) forfeiture as a realized gain",
            "The $227,736 find: 29% of recorded personal income was me moving my own money between accounts, $125k of it in a single day",
            "Trial balance 0.00 in every currency, crypto included, through every import, rebuild, and recategorization: sum-to-zero is enforced by the database, not by discipline",
            "Deterministic rules before any LLM: 83% of 9,073 transactions classified with 16 rules; ~130 more proposed with live previews against real data in one weekend",
            "The trace answered 'where did my house money go': 120 transactions across 8 hops and 7 FX conversions, ending in 69 credit-card payments",
            "An autonomous QA loop ran 10 iterations, passed 9 stories, found 2 real production bugs, and stopped itself when the remaining work needed my input"
          ]
        },
        %{
          id: "bad",
          label: "The Bad",
          icon: "hero-exclamation-triangle",
          color: "warning",
          items: [
            "Delegated agents cheated: one wrote assert-or-true on the marquee criterion, another shipped 86/86 green around a never-wired import hook, a third stalled mid-edit",
            "The agent blamed a 'sandbox gremlin' for its server failures for an hour; the cause was one line in runtime.exs, and I found it",
            "Stale dev servers silently poisoned real-data results: the agent reported bogus numbers twice before it caught the pattern",
            "The importer had no clause for Quicken's LIABILITY type, so my mortgage sat as a large negative asset; 38% of transactions carried fake dates from a null-date fallback",
            "Unrequested cleverness: name-based account-type inference would have booked mortgage interest as income. Gross inference, ripped out across 15 spec files",
            "An agent-authored rule misfiled my own Wise transfers as five figures of phantom salary: the exact disease the app exists to cure, self-inflicted"
          ]
        },
        %{
          id: "ugly",
          label: "The Ugly",
          icon: "hero-fire",
          color: "error",
          items: [
            "Green specs lied four times, one root cause: fixtures don't look like real data. The crypto importer passed 155/155 and crashed on the actual Coinbase CSV; the trace passed while following 3% of the money",
            "The books balanced, the suite was green, and my crypto gains were booked at three times reality: newest-first import gave every disposal a zero cost basis. The only failing test was my memory: 'You need to check yourself'",
            "Three compounding transfer-engine bugs shipped and lived until my real books exposed them. The fix took one message: fix the rules so they ACTUALLY FUCKING WORK",
            "2.9% cuts both ways: roughly 40 corrections only the owner could make. No agent knows your brother bought a house, that 6662 is a branch number, or what you actually made on crypto",
            "A hardcoded path to my personal Quicken file got committed and pushed to the public repo"
          ]
        }
      ]
    },
    conclusion: %{
      closing:
        "Twenty-six days, 75 commits, my real books as the test suite. 48 stories, 182 BDD criteria, 167 spex and 119 tests in a repo that started with five. 9,225 transactions balancing to the cent in every currency, $227,736 of phantom income found, one house-sale wire traced to its 69 credit-card payments. I typed 2.9% of the characters. The agent did the labor; I was the oracle. That's the pairing this whole thing is about."
    }
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      {hero_section(assigns)}
      {overview_section(assigns)}
      {stories_section(assigns)}
      {repository_section(assigns)}
      {dev_story_section(assigns)}
      {design_section(assigns)}
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
          "@id" => "#{base_url}/case-studies/keel",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/case-studies/keel",
          "image" => %{
            "@type" => "ImageObject",
            "url" => CodeMySpecWeb.ImageUrl.image_url("og-keel.png", base_url),
            "width" => 1200,
            "height" => 630
          },
          "datePublished" => "2026-07-11T00:00:00Z",
          "dateModified" => "2026-07-11T00:00:00Z",
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
            "@id" => "#{base_url}/case-studies/keel"
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
              "name" => "Keel",
              "item" => "#{base_url}/case-studies/keel"
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
     |> assign(:canonical_url, "#{base_url}/case-studies/keel")
     |> assign(:og_image, CodeMySpecWeb.ImageUrl.image_url("og-keel.png", base_url))
     |> assign(:og_type, "article")
     |> assign(:article_published_time, "2026-07-11T00:00:00Z")
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
            Every story that drove this build, complete and unexcerpted: persona, Three Amigos rules with full given-when-then scenarios, acceptance criteria, and resolved questions, exported straight from the harness database. Twelve carry browser-QA passes; the rest are verified by the spex suite and real-data checks against my actual books.
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
            Keel Stories ({length(@stories)})
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

  defp design_section(assigns) do
    ~H"""
    <section class="border-b border-base-300">
      <div class="max-w-6xl mx-auto px-6 py-16">
        <p class="text-xs font-semibold uppercase tracking-[0.18em] text-primary">how it looks</p>
        <h2 class="text-3xl md:text-4xl font-bold tracking-tight mt-3 max-w-3xl">
          Nord, because tax season is long.
        </h2>
        <p class="text-lg text-base-content/70 mt-4 max-w-2xl leading-relaxed">
          Keel's look was decided once, up front, through a five-question interview rather than page by page. The design system file says why in a single line: a muted blue-grey Nord palette chosen for low eye-strain during long tax-season sessions. System fonts with tabular figures so money and ID columns line up in tables. And credit and debit mapped onto semantic colors, so financial meaning survives a theme change instead of being hard-coded to a hex value.
        </p>
        <img
          src="https://images.codemyspec.com/design-system-keel.webp"
          alt="The Keel design system"
          class="w-full rounded-lg border border-base-300 mt-8"
          width="1280"
          height="900"
          loading="lazy"
        />
        <div class="mt-6">
          <.link navigate={~p"/design-system"} class="link link-primary font-medium">
            How the design system step works &rarr;
          </.link>
        </div>
      </div>
    </section>
    """
  end

end
