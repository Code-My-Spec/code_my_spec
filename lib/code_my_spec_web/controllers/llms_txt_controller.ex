defmodule CodeMySpecWeb.LlmsTxtController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  @content_types [:blog, :page, :documentation, :landing]

  @static_pages [
    %{title: "Homepage", url: "/", description: "Product overview and registration"},
    %{
      title: "Product",
      url: "/product",
      description:
        "The canonical product page: what CodeMySpec is, the seven-step build loop, architecture " <>
          "enforcement, verification, agentic QA, where it sits against coding agents and app " <>
          "builders, and why there is no lock-in"
    },
    %{
      title: "Pricing",
      url: "/pricing",
      description:
        "Free to build (harness + content engine, your own AI keys), $100/month per user to operate and grow, or built with you from $500 (quoted)"
    },
    %{
      title: "Design system",
      url: "/design-system",
      description:
        "The optional design step: answer five questions about how your project should look, and " <>
          "every page built after that has to reference your answers instead of inventing its own"
    },
    %{
      title: "Vibe coding rebuild service",
      url: "/vibe-coding-rebuild",
      description:
        "Done-with-you service: reverse-engineers a broken Lovable, Replit or Bolt app into " <>
          "written stories and executable specs, then rebuilds against them. Quoted, from $500"
    },
    %{
      title: "Supported AI agents",
      url: "/agents",
      description:
        "Which coding agents CodeMySpec runs inside (Claude Code flagship, OpenAI Codex and " <>
          "Google Antigravity early) and why the harness is agent-agnostic: it is a local server, " <>
          "and each plugin is a thin adapter"
    },
    %{
      title: "Developers",
      url: "/developers",
      description: "The free engineer build harness: your model, your code, no lock-in"
    },
    %{
      title: "Install",
      url: "/install",
      description: "Install the free build harness: local server plus Claude Code plugin"
    },
    %{
      title: "Methodology",
      url: "/methodology",
      description: "The six-phase CodeMySpec development method"
    },
    %{
      title: "Case Studies",
      url: "/case-studies",
      description: "Index of end-to-end teardowns of products built with CodeMySpec"
    },
    %{
      title: "MetricFlow Case Study",
      url: "/case-studies/metric-flow",
      description: "Full-stack Phoenix analytics app built with zero human-written code"
    },
    %{
      title: "Market My Spec Case Study",
      url: "/case-studies/market-my-spec",
      description:
        "Marketing-strategy product built with zero prompts and zero human-written code; configurable workflow, Three Amigos, and BDD-spec boundary protection"
    },
    %{
      title: "Cleaner CRM Case Study",
      url: "/case-studies/cleaner-crm",
      description:
        "Three-persona cleaning-business CRM two-shotted with Claude Fable 5 in three days; self-orchestrated loop, browser QA, real Stripe payments, live UAT, 0.4% of the conversation typed by the human"
    },
    %{
      title: "Keel Case Study",
      url: "/case-studies/keel",
      description:
        "Agent-first double-entry cross-border ledger built on the founder's real books over 26 days; 9,225 transactions balancing to the cent, $227,736 of phantom income found, 2.9% of the conversation typed by the human"
    },
    %{
      title: "Legwork Case Study",
      url: "/case-studies/legwork",
      description:
        "Outbound-process composer built in one weekend with Claude Opus 4.8; five-stage prose runbooks worked by an agent over 16 OAuth-authenticated MCP tools, human launch gate, 2.1% of the conversation typed by the human"
    },
    %{
      title: "EarWitness Live Build",
      url: "/case-studies/ear-witness",
      description:
        "Live harness build in progress: a local-first Otter alternative (on-device transcription, diarization, audio-tap meeting capture, MCP access). 11 stories with full Three Amigos records, statuses updating as browser QA passes"
    },
    %{
      title: "About",
      url: "/author/john-davenport",
      description: "About the founder and the project"
    }
  ]

  def index(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    content_by_type =
      @content_types
      |> Enum.map(fn type ->
        entries = ContentRepository.list_published_content(nil, type)
        {type, entries}
      end)
      |> Enum.reject(fn {_type, entries} -> entries == [] end)

    text = render_llms_txt(base_url, content_by_type)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, text)
  end

  def full(conn, _params) do
    base_url = CodeMySpecWeb.Endpoint.url()

    content_by_type =
      @content_types
      |> Enum.map(fn type ->
        entries = ContentRepository.list_published_content(nil, type)
        {type, entries}
      end)
      |> Enum.reject(fn {_type, entries} -> entries == [] end)

    text = render_llms_full_txt(base_url, content_by_type)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, text)
  end

  defp render_llms_txt(base_url, content_by_type) do
    sections = [
      header(),
      static_pages_section(base_url),
      content_sections(base_url, content_by_type),
      footer()
    ]

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp header do
    [
      "# CodeMySpec",
      "",
      "> CodeMySpec is a set of AI harnesses that help one person build, sell, and support real software. You do the thinking; the machine does the labor.",
      "",
      "license: CC-BY-SA-4.0",
      "allow: search, citation, summarization",
      "disallow: training",
      "",
      "## What is CodeMySpec?",
      "",
      "CodeMySpec is a set of AI harnesses for running a software business from one seat: build a real application with the model, operate it (customer email on your own domain, live chat), and grow it (content publishing, Google Ads, conversion reporting). Building is free forever with your own AI keys and no token markup; Operate & Grow is $100 a month per user. For developers, the free build harness drives your coding agent (Claude Code, plus OpenAI Codex and Google Antigravity) through a structured lifecycle — user stories, architecture design, BDD specifications, implementation, verification, and application QA. Its core innovation is that the specifications execute: each story's acceptance criteria become named rules, Gherkin scenarios, and executable specs that run against your code, so intent is continuously verified rather than documented. Specs and tests are real Elixir test files in your own repo, no lock-in.",
      "",
      "## What CodeMySpec does",
      "",
      "- Plans the work as a graph — models the project as stories, components, and requirements, and always tells the agent the single next thing to build.",
      "- Writes a specification before any code — every component gets a spec the agent must read; tests are generated from the spec; the implementation is written to pass the tests.",
      "- Understands 16 Phoenix/Elixir component types — contexts, schemas, repositories, LiveViews, GenServers, controllers, and more, each with its own design rules and requirement chain.",
      "- Enforces architecture — validates the dependency graph for circular references and boundary violations, and generates architecture views the agent reads as context.",
      "- Turns stories into tests — a Three Amigos process converts acceptance criteria into rules, Gherkin scenarios, and executable ExUnit tests.",
      "- Verifies every step automatically — on each stop it compiles the code, runs Credo, and runs the tests and Spex specs, and can block the agent from continuing on failure.",
      "- QAs the running application — a QA agent drives the live app in a real browser, per story or across the whole app, to catch bugs that pass unit tests.",
      "- Works across coding agents — ships as a plugin for Claude Code (the deepest integration), OpenAI Codex, and Google Antigravity; the harness is a local server, so your specs, tests, and code never depend on which agent wrote them.",
      "- Keeps you in control — your executable specifications and tests are real Elixir test files in your own repository, so they keep running with or without us; bring your own model and keys, with no markup on tokens and no lock-in.",
      "",
      "## How CodeMySpec compares",
      "",
      "CodeMySpec runs inside coding agents like Claude Code, Codex, and Antigravity — it is not an alternative to them, it is the lifecycle layer on top (specs, architecture, verification, QA). The tool it actually replaces is AI app builders like Lovable: CodeMySpec is the engineer's version — the app it produces is standard Phoenix in your own repo, one you can still maintain. It also goes further than spec-only tools (Kiro, GitHub Spec Kit), which generate specs and hand off; CodeMySpec does specs, tests, code, verification, and QA on one graph.",
      "",
      "## Who it's for",
      "",
      "Senior Phoenix/Elixir engineers, Elixir agencies, and solo technical founders shipping a real product — engineers using AI coding tools who want to keep architectural control as AI-generated volume grows.",
      ""
    ]
  end

  defp static_pages_section(base_url) do
    lines =
      @static_pages
      |> Enum.map(fn page ->
        "- [#{page.title}](#{base_url}#{page.url}): #{page.description}"
      end)

    ["## Key Pages", ""] ++ lines ++ [""]
  end

  defp content_sections(base_url, content_by_type) do
    Enum.flat_map(content_by_type, &type_section(&1, base_url))
  end

  defp type_section({type, entries}, base_url) do
    section_title = section_label(type)
    prefix = content_prefix(type)

    lines =
      entries
      |> Enum.sort_by(& &1.publish_at, {:desc, DateTime})
      |> Enum.map(&content_line(&1, base_url, prefix))

    ["## #{section_title}", ""] ++ lines ++ [""]
  end

  defp content_line(content, base_url, prefix) do
    title = content.title || content.slug
    desc = content.meta_description || ""
    desc_suffix = if desc != "", do: ": #{desc}", else: ""
    "- [#{title}](#{base_url}#{prefix}#{content.slug})#{desc_suffix}"
  end

  defp section_label(:blog), do: "Blog"
  defp section_label(:page), do: "Feature Pages & Comparisons"
  defp section_label(:documentation), do: "Documentation"
  defp section_label(:landing), do: "Landing Pages"

  defp content_prefix(:blog), do: "/blog/"
  defp content_prefix(:page), do: "/pages/"
  defp content_prefix(:documentation), do: "/documentation/"
  defp content_prefix(:landing), do: "/landing/"

  defp footer do
    [
      "## Contact",
      "",
      "- Website: https://codemyspec.com",
      "- GitHub: https://github.com/code-my-spec",
      "- Author: John Davenport (https://www.linkedin.com/in/john-davenport-software/)",
      ""
    ]
  end

  defp render_llms_full_txt(base_url, content_by_type) do
    sections = [
      header(),
      static_pages_section(base_url),
      full_content_sections(base_url, content_by_type),
      footer()
    ]

    sections
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp full_content_sections(base_url, content_by_type) do
    Enum.flat_map(content_by_type, fn {type, entries} ->
      prefix = content_prefix(type)

      header_lines = ["## #{section_label(type)}", ""]

      entry_lines =
        entries
        |> Enum.sort_by(& &1.publish_at, {:desc, DateTime})
        |> Enum.flat_map(fn content ->
          title = content.title || content.slug
          url = "#{base_url}#{prefix}#{content.slug}"
          body = strip_html(content.processed_content || "")

          [
            "### [#{title}](#{url})",
            "",
            body,
            "",
            "---",
            ""
          ]
        end)

      header_lines ++ entry_lines
    end)
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/&#39;/, "'")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
