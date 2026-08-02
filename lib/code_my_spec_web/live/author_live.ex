defmodule CodeMySpecWeb.AuthorLive do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Content.ContentRepository
  alias CodeMySpecWeb.Layouts

  @author_url "https://codemyspec.com/author/john-davenport"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto px-4 py-12">
        <article>
          <header class="mb-10">
            <h1 class="text-4xl font-extrabold tracking-tight mb-2">John Davenport</h1>
            <p class="text-xl text-base-content/70">Founder, CodeMySpec</p>
          </header>

          <div class="prose prose-lg max-w-none prose-headings:font-bold prose-headings:tracking-tight prose-a:text-primary">
            <p>
              Full-stack engineer with 15 years of experience spanning enterprise systems, manufacturing IT, fintech, and AI-assisted development tooling. I build tools that help developers ship production software with AI — not by replacing architects, but by giving AI agents the structured workflows they need to write code that actually works.
            </p>

            <p>
              CodeMySpec is my current project: an AI development harness for Elixir/Phoenix applications that enforces the full loop from user stories through architecture, BDD specs, implementation, and QA. I built seven production applications with it —
              <a href="/case-studies/metric-flow">MetricFlow</a>
              (40 commits, 13 days, zero human-written code), Fuellytics (a fuel card fraud detection platform with 5-validator pipeline, Claude Vision OCR, and Stripe Issuing integration),
              <a href="/case-studies/market-my-spec">Market My Spec</a>
              (a small MCP server that exposes a marketing-strategy skill to Claude Code, shipped across one weekend with zero prompts and zero lines of code),
              <a href="/case-studies/cleaner-crm">Cleaner CRM</a>
              (a three-persona cleaning-business CRM two-shotted with Claude Fable 5 in three days; I typed 0.4% of the characters in the build conversation),
              <a href="/case-studies/keel">Keel</a>
              (an agent-first double-entry ledger running my own cross-border books; the agent found $227k of phantom income Quicken had miscounted),
              <a href="/case-studies/legwork">Legwork</a>
              (an outbound-process composer built in a weekend, where the agent works five-stage runbooks over OAuth-authenticated MCP and the human keeps the launch gate), and
              <a href="/case-studies/broken-oaths">Broken Oaths</a>
              (a persistent hex-globe 4X strategy game, the most complicated thing I have built this way: 108,734 lines of Elixir in a 12-day sprint, live in production with real playtesters) — to prove the methodology works before asking anyone else to use it.
            </p>

            <h2>Career Path</h2>
            <p>
              I started in hardware design at GE Intelligent Platforms, designing embedded computing solutions — VME and CompactPCI single board computers for military, aerospace, and industrial customers. That gave me a foundation in systems thinking that's shaped everything since.
            </p>
            <p>
              From there I moved into manufacturing IT at Enova Premier, managing production systems across 4 automotive plants for a tier-one supplier assembling wheels and tires for Toyota, GM, and Hyundai. I built an industrial IoT platform combining OPC UA, real-time PLC data, and GraphQL APIs into operator-facing Vue.js applications — and hired and trained the first software development team the company ever had.
            </p>
            <p>
              I spent three years at FunnelCloud as Head of Implementations, leading technical operations for an MES vendor serving 50-60 automotive plants. Then three years at Openforce as a software engineer on IC Insure — an insurance marketplace built on an Elixir/Phoenix monolith with CQRS, Event Sourcing (Commanded), and GraphQL (Absinthe), serving clients including American Express and Hudson Insurance Group.
            </p>
            <p>
              Along the way I founded several products that taught me more than they earned:
              <strong>UserDocs</strong>
              (documentation automation, three major architectural rewrites, secured a pilot with Chef),
              <strong>Discussit</strong>
              (conversation intelligence with LLM-powered topic analysis), and
              <strong>Desert First Cleaning</strong>
              (which actually did work — $252K+ revenue, 150% YoY growth).
            </p>

            <h2>What I've Built</h2>
            <ul>
              <li>
                <strong>CodeMySpec</strong>
                — AI development harness for Phoenix. 368 modules, 46 bounded contexts, compile-time dependency enforcement. MCP servers for product management and architecture, BDD spec generation, session orchestration, and automated QA. Ships as a Claude Code extension.
              </li>
              <li>
                <strong>Fuellytics</strong>
                — Fleet fuel card fraud detection platform. 5-validator pipeline, Claude Vision OCR, Stripe Issuing/Treasury/Connect, Twilio SMS. Built with CodeMySpec in 55 commits, zero human-written code.
              </li>
              <li>
                <strong>MetricFlow</strong>
                — Cross-platform ad analytics correlating Google Ads, Facebook Ads, and GA4 with QuickBooks revenue. Pearson correlation engine, Claude-powered insights. <a href="/case-studies/metric-flow">40 commits, 13 days, honest assessment</a>.
              </li>
              <li>
                <strong>Market My Spec</strong>
                — Small MCP server that exposes a marketing-strategy skill to Claude Code. Multi-tenant accounts with agency tier, magic-link auth, OAuth scaffolding, eight-step strategy walkthrough delivered over MCP. <a href="/case-studies/market-my-spec">17 commits across 4 days, zero prompts, zero lines of code</a>.
              </li>
              <li>
                <strong>Cleaner CRM</strong>
                — Three-persona CRM for cleaning businesses: owner back office, cleaner field app, public booking funnel with real Stripe payments. Two-shotted with Claude Fable 5 in three days on a self-orchestrating loop; 0.4% of the conversation typed by a human. <a href="/case-studies/cleaner-crm">21 stories, 143 BDD criteria, honest teardown</a>.
              </li>
              <li>
                <strong>Keel</strong>
                — Agent-first, multi-currency, double-entry ledger running my own cross-border books. Quicken SQLite import, deterministic rules engine with an LLM tail, 22 intent-level MCP tools, crypto as asset-as-currency. The agent found $227,736 of phantom income. <a href="/case-studies/keel">48 stories, 182 BDD criteria, honest teardown</a>.
              </li>
              <li>
                <strong>Legwork</strong>
                — Outbound-process composer: five-stage prose runbooks an LLM agent works via 16 OAuth-authenticated MCP tools, with a human launch gate. Built in one weekend with Claude Opus 4.8; gating real prospects on day two. <a href="/case-studies/legwork">7 stories, 47 BDD criteria, honest teardown</a>.
              </li>
              <li>
                <strong>Broken Oaths</strong>
                — Persistent hex-globe 4X strategy game where losing a war makes you a vassal rather than a corpse: Goldberg polyhedron mesh, per-world GenServer simulation, feudal vassalage and rebellion. Built in a 12-day sprint; 108,734 lines of Elixir, 0.25% of the conversation typed by a human. <a href="/case-studies/broken-oaths">52 stories, 387 BDD criteria, honest teardown</a>.
              </li>
              <li>
                <strong>IC Insure</strong>
                — Insurance marketplace for independent contractors. Elixir/Phoenix, CQRS/Event Sourcing, 11 bounded contexts, 20+ supervised processes. One of two engineers.
              </li>
              <li>
                <strong>UserDocs</strong>
                — Browser automation for documentation. Phoenix LiveView, Chrome DevTools Protocol, multi-tenant architecture. Three major rewrites.
              </li>
              <li>
                <strong>Discussit</strong>
                — Conversation intelligence platform with Zoom/OpenPhone ingestion, transcription, and LLM-powered topic clustering.
              </li>
            </ul>

            <h2>Technical Focus</h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-1 not-prose mb-6">
              <div>
                <h3 class="font-semibold text-base mt-4 mb-2">Languages & Frameworks</h3>
                <p class="text-base-content/70 text-sm">
                  Elixir, Phoenix, LiveView, OTP, Python, TypeScript, C#, Blazor, Vue.js, React
                </p>
              </div>
              <div>
                <h3 class="font-semibold text-base mt-4 mb-2">AI & LLM Engineering</h3>
                <p class="text-base-content/70 text-sm">
                  Claude API, MCP servers, agentic workflows, BDD spec generation, embedding pipelines, RAG
                </p>
              </div>
              <div>
                <h3 class="font-semibold text-base mt-4 mb-2">Architecture</h3>
                <p class="text-base-content/70 text-sm">
                  CQRS, Event Sourcing, DDD, bounded contexts, dependency graphs, multi-tenant systems
                </p>
              </div>
              <div>
                <h3 class="font-semibold text-base mt-4 mb-2">Data & Infrastructure</h3>
                <p class="text-base-content/70 text-sm">
                  PostgreSQL, Snowflake, SQLite, Docker, Fly.io, GitHub Actions, OPC UA, industrial IoT
                </p>
              </div>
            </div>

            <h2>Connect</h2>
            <ul>
              <li>
                <a
                  href="https://www.linkedin.com/in/john-davenport-software/"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  LinkedIn
                </a>
              </li>
              <li>
                <a href="https://x.com/johns10d" target="_blank" rel="noopener noreferrer">
                  X / Twitter
                </a>
              </li>
              <li>
                <a
                  href="https://www.youtube.com/@codemyspec"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  YouTube
                </a>
              </li>
              <li>
                <a href="https://github.com/code-my-spec" target="_blank" rel="noopener noreferrer">
                  GitHub
                </a>
              </li>
              <li>
                <a
                  href="https://www.reddit.com/user/johns10davenport/"
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Reddit
                </a>
              </li>
              <li>
                <a href="https://john.davenport.rocks" target="_blank" rel="noopener noreferrer">
                  Full Resume
                </a>
              </li>
            </ul>
          </div>

          <div class="mt-10 pt-8 border-t border-base-300">
            <a href="/pages/founder-story" class="btn btn-ghost gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the full founder story
            </a>
          </div>
        </article>
        
    <!-- Published Articles -->
        <section :if={@blog_posts != []} class="mt-16">
          <h2 class="text-3xl font-bold tracking-tight mb-8">Published Articles</h2>
          <div class="space-y-4">
            <a
              :for={post <- @blog_posts}
              href={"/blog/#{post.slug}"}
              class="block card bg-base-100 border border-base-300 hover:shadow-lg transition-shadow"
            >
              <div class="card-body py-4 px-5">
                <div class="flex items-center justify-between gap-4">
                  <span class="font-medium">{post.title || post.slug}</span>
                  <span :if={post.publish_at} class="text-sm text-base-content/50 whitespace-nowrap">
                    {Calendar.strftime(post.publish_at, "%b %d, %Y")}
                  </span>
                </div>
              </div>
            </a>
          </div>
        </section>
      </div>
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    base_url = CodeMySpecWeb.Endpoint.url()

    blog_posts =
      ContentRepository.list_published_content(nil, :blog)
      |> Enum.sort_by(
        fn post ->
          case post.publish_at do
            nil -> ~U[1970-01-01 00:00:00Z]
            datetime -> datetime
          end
        end,
        {:desc, DateTime}
      )

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "Person",
          "@id" => @author_url,
          "name" => "John Davenport",
          "jobTitle" => "Founder",
          "url" => @author_url,
          "description" =>
            "Full-stack engineer with 15 years of experience. Founder of CodeMySpec. Background in hardware engineering (GE), manufacturing IT, enterprise insurance systems (Elixir/Phoenix), and AI-assisted development tooling.",
          "image" => %{
            "@type" => "ImageObject",
            "url" => CodeMySpecWeb.ImageUrl.image_url("john-davenport.jpg", base_url),
            "width" => 400,
            "height" => 400
          },
          "worksFor" => %{
            "@type" => "Organization",
            "@id" => "#{base_url}/#organization",
            "name" => "CodeMySpec"
          },
          "sameAs" => [
            "https://github.com/johns10",
            "https://www.linkedin.com/in/john-davenport-software/",
            "https://x.com/johns10d",
            "https://www.youtube.com/@codemyspec",
            "https://www.reddit.com/user/johns10davenport/",
            "https://john.davenport.rocks"
          ],
          "knowsAbout" => [
            "Elixir",
            "Phoenix Framework",
            "Phoenix LiveView",
            "OTP",
            "AI-assisted software development",
            "Model Context Protocol",
            "BDD testing",
            "Software architecture",
            "CQRS and Event Sourcing",
            "Domain-Driven Design",
            "Manufacturing IT",
            "Industrial IoT",
            "PostgreSQL",
            "Embedded systems",
            "Enterprise insurance systems"
          ]
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "ProfilePage",
          "@id" => "#{@author_url}#profilepage",
          "url" => @author_url,
          "name" => "John Davenport — Author Profile",
          "mainEntity" => %{"@id" => @author_url}
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{"@type" => "ListItem", "position" => 2, "name" => "John Davenport"}
          ]
        }
      ])

    {:ok,
     socket
     |> assign(:blog_posts, blog_posts)
     |> assign(:page_title, "John Davenport — Founder, CodeMySpec")
     |> assign(
       :meta_description,
       "Full-stack engineer with 15 years of experience. Founder of CodeMySpec. Background in hardware engineering, manufacturing IT, enterprise systems, and AI-assisted development."
     )
     |> assign(:og_title, "John Davenport — Founder, CodeMySpec")
     |> assign(
       :og_description,
       "15 years of experience from hardware design to AI-assisted development. Building tools that help developers ship production software with AI."
     )
     |> assign(:og_image, CodeMySpecWeb.ImageUrl.image_url("john-davenport.jpg", base_url))
     |> assign(:canonical_url, @author_url)
     |> assign(:json_ld, json_ld)}
  end
end
