defmodule CodeMySpecWeb.Markdown do
  @moduledoc """
  Renders genuinely-markdown payloads to safe HTML for the local dashboard and the cloud app.

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
        gfm: true,
        # Off, because most of what goes through here is not prose.
        #
        # Earmark defaults it on, and it rewrites `--` to an en-dash and both
        # quote characters to their curly forms anywhere outside a code span.
        # Agent transcripts are full of shell that is not in one — the recorder
        # writes a tool call as "<tool>\n<arguments>", plain text — so every
        # command in a transcript rendered as
        #
        #     bash curl -sS –max-time 10 “$CMS_SERVER_URL” -H ‘a: b’
        #
        # which is unrunnable and, worse, looks right. The transcript is where
        # somebody checks what an agent did; a command that cannot be re-run
        # cannot be checked. Curly quotes in the prose beside it are not worth
        # that.
        smartypants: false
      })

    {:safe, html}
  end
end
