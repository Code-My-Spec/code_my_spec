defmodule CodeMySpecWeb.Plugs.LegacyRedirects do
  @moduledoc """
  Issues 301 redirects for content that has moved between content types
  (typically /pages/{slug} → /blog/{slug} after a page-to-blog migration).

  Add new entries to @page_to_blog_slugs as content migrates.
  """
  import Plug.Conn

  @page_to_blog_slugs ~w(
    agentic-qa
    ai-ides-compared-2026
    aider-review-2026
    bdd-specs-for-ai-generated-code
    claude-code-review-2026
    claude-code-skills-guide
    cli-agents-compared-2026
    codemyspec-vs-kiro-specs
    codex-cli-review-2026
    cursor-review-2026
    dead-ai-coding-tools-supermaven-aide-void
    five-layers-of-agentic-coding
    five-levels-of-ai-coding
    free-open-source-ai-coding-tools-2026
    gemini-cli-review-2026
    github-copilot-review-2026
    managing-architecture
    managing-user-stories
    mcp-protocol-explained
    open-source-vs-vendor-locked-ai-coding-tools
    progressive-disclosure
    rise-of-cli-coding-agents
    the-agent-layer
    the-environment-layer
    the-harness-layer
    the-model-layer
    the-orchestration-layer
    writing-applications-for-llms
    writing-design-documents
  )

  @redirects Map.new(@page_to_blog_slugs, fn slug ->
               {"/pages/#{slug}", "/blog/#{slug}"}
             end)

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _opts) do
    case Map.fetch(@redirects, path) do
      {:ok, target} ->
        location = append_query(target, conn.query_string)

        conn
        |> put_resp_header("location", location)
        |> send_resp(301, "")
        |> halt()

      :error ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  defp append_query(path, ""), do: path
  defp append_query(path, query), do: path <> "?" <> query
end
