defmodule CodeMySpecWeb.AuthorLive do
  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @author_url "https://codemyspec.com/author/john-davenport"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto px-4 py-12">
        <article>
          <header class="mb-10">
            <h1 class="text-4xl font-extrabold mb-2">John Davenport</h1>
            <p class="text-xl text-base-content/70">Founder, CodeMySpec</p>
          </header>

          <div class="prose prose-lg max-w-none">
            <p>
              I build tools that help developers ship production software with AI. CodeMySpec is my current project — a structured development platform for Phoenix applications that enforces the full loop from user stories through BDD specs, implementation, and QA.
            </p>

            <h2>Background</h2>
            <p>
              15 years in enterprise systems and software development. Deep expertise in Elixir, Phoenix, and OTP. The last 2 years have been focused exclusively on LLM-assisted development tooling — building, testing, and iterating on workflows that produce code that actually works in production.
            </p>

            <h2>What I've Built</h2>
            <ul>
              <li><strong>CodeMySpec</strong> — Structured AI development platform for Phoenix. MCP servers for product management and architecture, BDD spec generation, session orchestration, and automated QA.</li>
              <li><strong>MetricFlow</strong> — Full-stack Phoenix analytics platform built with zero human-written code. <a href="/case-studies/metric-flow">40 commits, 13 days, honest assessment</a>.</li>
              <li><strong>UserDocs</strong> — Browser automation tool for web application documentation. Phoenix LiveView.</li>
              <li><strong>Discussit</strong> — LLM-powered communication analysis platform.</li>
            </ul>

            <h2>Technical Focus</h2>
            <ul>
              <li>Elixir, Phoenix, LiveView, OTP</li>
              <li>MCP (Model Context Protocol) server development</li>
              <li>BDD with Gherkin scenarios and automated verification</li>
              <li>Bounded context architecture and dependency graphs</li>
              <li>Claude Code, agentic workflows, structured AI development</li>
            </ul>

            <h2>Connect</h2>
            <ul>
              <li><a href="https://www.linkedin.com/in/john-davenport-software/" target="_blank" rel="noopener noreferrer">LinkedIn</a></li>
              <li><a href="https://x.com/johns10d" target="_blank" rel="noopener noreferrer">X / Twitter</a></li>
              <li><a href="https://www.youtube.com/@codemyspec" target="_blank" rel="noopener noreferrer">YouTube</a></li>
              <li><a href="https://github.com/code-my-spec" target="_blank" rel="noopener noreferrer">GitHub</a></li>
            </ul>
          </div>

          <div class="mt-10 pt-8 border-t border-base-300">
            <a href="/pages/founder-story" class="btn btn-ghost gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the full founder story
            </a>
          </div>
        </article>
      </div>
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
          "@type" => "Person",
          "@id" => @author_url,
          "name" => "John Davenport",
          "jobTitle" => "Founder",
          "url" => @author_url,
          "description" => "Founder of CodeMySpec. 15 years in enterprise systems, building structured AI-assisted development workflows for Phoenix applications.",
          "image" => %{
            "@type" => "ImageObject",
            "url" => "#{base_url}/images/john-davenport.jpg",
            "width" => 400,
            "height" => 400
          },
          "worksFor" => %{
            "@type" => "Organization",
            "@id" => "#{base_url}/#organization",
            "name" => "CodeMySpec"
          },
          "sameAs" => [
            "https://www.linkedin.com/in/john-davenport-software/",
            "https://x.com/johns10d",
            "https://github.com/code-my-spec",
            "https://www.youtube.com/@codemyspec",
            "https://www.reddit.com/user/johns10davenport/"
          ],
          "knowsAbout" => [
            "Elixir",
            "Phoenix Framework",
            "AI-assisted development",
            "Model Context Protocol",
            "BDD testing",
            "Software architecture"
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
     |> assign(:page_title, "John Davenport — Founder, CodeMySpec")
     |> assign(:meta_description, "Founder of CodeMySpec. 15 years in enterprise systems, building AI-assisted development tooling for Phoenix.")
     |> assign(:og_title, "John Davenport — Founder, CodeMySpec")
     |> assign(:og_description, "Building tools that help developers ship production software with AI.")
     |> assign(:og_image, "#{base_url}/images/john-davenport.jpg")
     |> assign(:canonical_url, @author_url)
     |> assign(:json_ld, json_ld)}
  end
end
