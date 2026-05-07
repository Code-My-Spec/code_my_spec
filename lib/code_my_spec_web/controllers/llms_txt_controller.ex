defmodule CodeMySpecWeb.LlmsTxtController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.Content.ContentRepository

  @content_types [:blog, :page, :documentation, :landing]

  @static_pages [
    %{title: "Homepage", url: "/", description: "Product overview and registration"},
    %{title: "Methodology", url: "/methodology", description: "The six-phase CodeMySpec development method"},
    %{title: "Case Studies", url: "/case-studies", description: "Index of end-to-end teardowns of products built with CodeMySpec"},
    %{title: "MetricFlow Case Study", url: "/case-studies/metric-flow", description: "Full-stack Phoenix analytics app built with zero human-written code"},
    %{title: "Market My Spec Case Study", url: "/case-studies/market-my-spec", description: "Marketing-strategy product built with zero prompts and zero human-written code; configurable workflow, Three Amigos, and BDD-spec boundary protection"},
    %{title: "About", url: "/author/john-davenport", description: "About the founder and the project"}
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
      "> AI-assisted Phoenix development that actually ships. Structured workflows guide AI through design, testing, and implementation with human oversight.",
      "",
      "license: CC-BY-SA-4.0",
      "allow: search, citation, summarization",
      "disallow: training",
      "",
      "## What is CodeMySpec?",
      "",
      "CodeMySpec is a development platform that uses structured workflows, clear component boundaries, and human-in-the-loop oversight to build production-ready Phoenix (Elixir) applications with AI agents. It enforces a six-phase process: user stories, architecture design, BDD specifications, implementation, verification, and application QA.",
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
