defmodule CmsHarness.Web.UpstreamError do
  @moduledoc """
  Reading a server error page down to the one sentence that explains it.

  A wedged dev server answers every request with Phoenix's debug page, and more
  than one path here forwards what the server said. Relayed whole, that is 30KB
  of markup and a base64 SVG logo where a result belonged — into an agent's
  context through MCP (`5fb011f4`), or into a single log line on the permission
  path, where it is the same document doing the same damage to a different
  reader.

  One implementation rather than a copy per caller: the hard part is not
  detecting the page but choosing which 300 characters come out of it, and two
  copies of that drift silently — the summary keeps being produced, just a worse
  one.
  """

  @doc """
  A one-line account of a server error page, or `nil` if it is not one.

  Public so the extraction can be asserted directly against the shapes Phoenix
  actually sends — the failure here was never in *detecting* the page, it was in
  which 300 characters got picked out of it.
  """
  @spec summary(String.t(), integer(), String.t() | nil) :: String.t() | nil
  def summary(body, status, content_type) do
    if error_page?(body, status, content_type) do
      "the CodeMySpec server answered with an error page (HTTP #{status}) " <>
        "instead of a tool result: #{exception_text(body)}. " <>
        "Common causes: a pending migration, or a dev server that has loaded a " <>
        "changed config/*.exs and cannot hot-reload it. Both persist until the " <>
        "server is dealt with, so every request fails the same way."
    end
  end

  # Not only HTML. Phoenix renders its debug page in whatever the request
  # accepts, and the MCP client sends `application/json, text/event-stream` — so
  # a `Phoenix.Ecto.PendingMigrationError` came back as markdown, sailed past an
  # HTML-only check, and reached the agent as a raw stack trace. Recognising the
  # page by its exception marker as well as its markup catches both renderings.
  defp error_page?(body, status, content_type) do
    trimmed = String.trim_leading(body)

    content_type == "text/html" or
      String.starts_with?(trimmed, ["<!DOCTYPE", "<!doctype", "<html"]) or
      (status >= 400 and String.contains?(body, "** ("))
  end

  # Inline `<style>` and `<script>` bodies survive tag-stripping, and Phoenix's
  # debug page opens with one. Taking the first 300 characters of the stripped
  # document therefore returned the stylesheet:
  #
  #     CompileError /*! normalize.css v4.2.0 | MIT License | … */html{font-…
  #
  # received verbatim through this transport, with the sentence that mattered —
  # "could not compile application … You must restart your server" — never
  # arriving. An agent that truncates long tool results got CSS and no cause.
  @noise ~r{<(style|script)\b[^>]*>.*?</\1>}is

  defp exception_text(body) do
    text =
      body
      |> String.replace(@noise, " ")
      |> String.replace(~r{<[^>]*>}, " ")
      |> unescape()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    # The marker wins where there is one: it is the line naming what broke, and
    # a page can carry any amount of chrome before it.
    case String.split(text, "** (", parts: 2) do
      [_before, rest] -> "** (" <> String.slice(rest, 0, 300)
      [_] -> fallback_text(text)
    end
  end

  defp fallback_text(""), do: "no readable text in the response"
  defp fallback_text(text), do: String.slice(text, 0, 300)

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

end
