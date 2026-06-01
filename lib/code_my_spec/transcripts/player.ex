defmodule CodeMySpec.Transcripts.Player do
  @moduledoc """
  Cinematic terminal renderer for a Claude Code transcript.

  Walks the transcript's entries in order and prints a Claude-Code-styled
  terminal view — assistant narration, `⏺ Tool(...)` actions, `⎿ result`
  snippets — pacing between blocks for a watchable speed. While rendering, it
  fires the same state-changing ops into the harness via `Replayer.fire/2`, so
  the recorded terminal session and the live web UI play **in tandem from one
  loop**: the terminal shows the agent working, the browser shows the project
  filling in.

  Rendering uses the *recorded* tool results (faithful to the original session);
  the harness ops fire *live* (so the UI updates). Pure read/search ops render
  but make no harness change.
  """

  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.Replayer
  alias CodeMySpec.Transcripts.ClaudeCode.{Entry, ToolCall}

  @harness_prefix "mcp__plugin_codemyspec_local__"
  @text_cap 700
  @result_cap 200

  @doc """
  Play a transcript as a paced terminal session.

  ## Options
    * `:mcp_url`    — harness MCP endpoint (nil = render only, no harness writes)
    * `:target_dir` — project dir for file ops (default /tmp/cms_demo_mms)
    * `:source_cwd` — override recorded cwd for path rewriting
    * `:delay_ms`   — pause between rendered blocks (playback speed)
    * `:from`/`:to` — entry index range (play to a point, pause, resume)
  """
  @spec play(Path.t(), keyword()) :: :ok
  def play(path, opts \\ []) do
    {:ok, transcript} = Transcripts.parse(path)

    ctx = %{
      source_cwd: opts[:source_cwd] || cwd_from(transcript),
      target_dir: opts[:target_dir] || "/tmp/cms_demo_mms",
      mcp_url: opts[:mcp_url]
    }

    delay = opts[:delay_ms] || 0
    from = opts[:from] || 0
    to = opts[:to]

    transcript.entries
    |> Enum.with_index()
    |> Enum.filter(fn {_e, i} -> i >= from and (is_nil(to) or i < to) end)
    |> Enum.each(fn {entry, _i} -> render_entry(entry, ctx, delay) end)

    :ok
  end

  defp render_entry(%Entry{type: type, message: msg}, ctx, delay) when is_map(msg) do
    case msg["content"] do
      content when is_list(content) ->
        Enum.each(content, &render_block(&1, type, ctx, delay))

      text when is_binary(text) and text != "" ->
        render_block(%{"type" => "text", "text" => text}, type, ctx, delay)

      _ ->
        :ok
    end
  end

  defp render_entry(_entry, _ctx, _delay), do: :ok

  # -- text: human prompt vs agent narration (skip slash-command metadata) --
  defp render_block(%{"type" => "text", "text" => text}, type, _ctx, delay)
       when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" or command_noise?(trimmed) ->
        :ok

      type == "user" ->
        puts([IO.ANSI.bright(), IO.ANSI.green(), "▶ ", cap(trimmed, @text_cap), IO.ANSI.reset()])
        beat(delay)

      true ->
        puts([IO.ANSI.bright(), IO.ANSI.white(), cap(trimmed, @text_cap), IO.ANSI.reset()])
        beat(delay)
    end
  end

  # -- tool action: render Claude-Code style + fire the real op -------------
  defp render_block(%{"type" => "tool_use"} = block, _type, ctx, delay) do
    tool_call = ToolCall.new(block)
    puts([IO.ANSI.cyan(), "⏺ ", action_label(tool_call), IO.ANSI.reset()])
    Replayer.fire(tool_call, ctx)
    beat(delay)
  end

  # -- recorded tool result -------------------------------------------------
  defp render_block(%{"type" => "tool_result"} = block, _type, _ctx, delay) do
    text = block |> result_text() |> String.trim()

    if text != "" do
      puts([IO.ANSI.faint(), "  ⎿  ", cap(first_line(text), @result_cap), IO.ANSI.reset()])
      beat(delay)
    end
  end

  defp render_block(_block, _type, _ctx, _delay), do: :ok

  # Slash-command + local-command metadata that Claude Code injects as user
  # text — noise for a demo terminal, not something the human or agent "said".
  defp command_noise?(text) do
    String.contains?(text, "<command-name>") or
      String.contains?(text, "<local-command-caveat>") or
      String.contains?(text, "<command-message>") or
      String.starts_with?(text, "<command-")
  end

  # -- action labels (Claude Code-ish) --------------------------------------
  defp action_label(%ToolCall{name: "Bash", input: i}), do: "Bash(#{first_line(i["command"] || "")})"
  defp action_label(%ToolCall{name: "Write", input: i}), do: "Write(#{rel(i["file_path"])})"
  defp action_label(%ToolCall{name: "Edit", input: i}), do: "Edit(#{rel(i["file_path"])})"
  defp action_label(%ToolCall{name: "Read", input: i}), do: "Read(#{rel(i["file_path"])})"

  defp action_label(%ToolCall{name: @harness_prefix <> tool, input: i}),
    do: "#{tool}(#{args(i)})"

  defp action_label(%ToolCall{name: "mcp__" <> rest}), do: rest |> String.split("__") |> List.last()
  defp action_label(%ToolCall{name: name}), do: name

  defp args(input) when is_map(input) do
    input
    |> Map.take(["story_id", "title", "statement", "requirement_name", "path", "name", "component_name"])
    |> Enum.map(fn {k, v} -> "#{k}: #{cap(to_string(v), 48)}" end)
    |> Enum.join(", ")
  end

  defp args(_), do: ""

  # -- helpers --------------------------------------------------------------
  defp result_text(%{"content" => content}) when is_list(content),
    do: content |> Enum.map(fn b -> is_map(b) && b["text"] end) |> Enum.filter(& &1) |> Enum.join(" ")

  defp result_text(%{"content" => content}) when is_binary(content), do: content
  defp result_text(_), do: ""

  defp rel(nil), do: "?"
  defp rel(path), do: Regex.replace(~r{^.*/(market_my_spec|cms_demo_mms)/}, path, "")

  defp first_line(s), do: s |> to_string() |> String.split("\n", parts: 2) |> hd()

  defp cap(s, n) do
    s = to_string(s)
    if String.length(s) > n, do: String.slice(s, 0, n) <> "…", else: s
  end

  defp cwd_from(transcript) do
    case Enum.find(transcript.entries, &(&1.cwd != nil)) do
      nil -> "/"
      entry -> entry.cwd
    end
  end

  defp puts(iodata), do: IO.puts(IO.iodata_to_binary(iodata))
  defp beat(0), do: :ok
  defp beat(ms), do: Process.sleep(ms)
end
