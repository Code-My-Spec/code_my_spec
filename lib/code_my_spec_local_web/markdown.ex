defmodule CodeMySpecLocalWeb.Markdown do
  @moduledoc """
  Renders genuinely-markdown payloads to safe HTML for the local dashboard.

  Use this ONLY for content that is authored as markdown — agent prompts and
  commands from `*.command/2`, the next-task prompt, on-disk spec docs, and the
  architecture overview. Structured data (the requirements graph, component and
  story lists) is rendered directly from the data, not through here.
  """

  @doc """
  Convert a markdown string to a `{:safe, iodata}` tuple for direct
  interpolation in a HEEx template (`{md_html(@page.command)}`).

  Returns an empty safe value for `nil`.
  """
  def md_html(nil), do: {:safe, ""}

  def md_html(markdown) when is_binary(markdown) do
    html =
      Earmark.as_html!(markdown, %Earmark.Options{
        compact_output: true,
        breaks: true,
        gfm: true
      })

    {:safe, html}
  end
end
