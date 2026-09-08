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
  alias CodeMySpec.Transcripts.ClaudeCode.{Entry, ToolCall}
  alias CodeMySpec.Transcripts.Replayer
  alias IO.ANSI

  @harness_prefix "mcp__plugin_codemyspec_local__"
  @text_cap 700
  @result_cap 200

  # AskUserQuestion renders in the user's browser, not the terminal, so a
  # replay that prints only the tool name drops the most informative thing in
  # an interview session: the options, and the reasoning attached to each one.
  # Those descriptions are where you can see the agent has already read the
  # persona and the codebase before it asked anything.
  @option_width 62
  @option_desc_lines 3
  # An answer block is a list, one line per question. Capping it at the first
  # line prints "The user answered on their phone:" and nothing else.
  @answer_cap 12

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

    base_delay = opts[:delay_ms] || 0

    ctx = %{
      source_cwd: opts[:source_cwd] || cwd_from(transcript),
      target_dir: opts[:target_dir] || "/tmp/cms_demo_mms",
      mcp_url: opts[:mcp_url],
      pacing: normalize_pacing(opts[:pacing], base_delay),
      session_id: seed_session(transcript, opts)
    }

    from = opts[:from] || 0
    to = opts[:to]

    transcript.entries
    |> Enum.with_index()
    |> Enum.filter(fn {_e, i} -> i >= from and (is_nil(to) or i < to) end)
    |> Enum.each(fn {entry, i} -> render_entry(entry, i, ctx) end)

    :ok
  end

  defp render_entry(%Entry{type: type, message: msg}, index, ctx) when is_map(msg) do
    case msg["content"] do
      content when is_list(content) ->
        Enum.each(content, &render_block(&1, type, index, ctx))

      text when is_binary(text) and text != "" ->
        render_block(%{"type" => "text", "text" => text}, type, index, ctx)

      _ ->
        :ok
    end
  end

  defp render_entry(_entry, _index, _ctx), do: :ok

  # -- text: human prompt vs agent narration (skip slash-command metadata) --
  defp render_block(%{"type" => "text", "text" => text}, type, index, ctx)
       when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" or command_noise?(trimmed) ->
        :ok

      invocation = command_invocation(trimmed) ->
        puts([ANSI.bright(), ANSI.green(), "▶ ", invocation, ANSI.reset()])
        beat(delay_for(index, ctx))

      type == "user" ->
        puts([ANSI.bright(), ANSI.green(), "▶ ", cap(trimmed, @text_cap), ANSI.reset()])
        beat(delay_for(index, ctx))

      true ->
        puts([ANSI.bright(), ANSI.white(), cap(trimmed, @text_cap), ANSI.reset()])
        beat(delay_for(index, ctx))
    end
  end

  # -- the interview question, expanded ------------------------------------
  defp render_block(
         %{"type" => "tool_use", "name" => "AskUserQuestion", "input" => input},
         _type,
         index,
         ctx
       ) do
    puts([ANSI.cyan(), "⏺ AskUserQuestion", ANSI.reset()])

    questions = input["questions"] || []

    # Spread the block's delay across the options instead of dumping the whole
    # prompt and then sleeping. The options arriving one at a time is the beat
    # worth watching — it is the moment the choice is being put to you — and
    # pacing still behaves, because the pieces sum to the block's delay.
    option_count = questions |> Enum.flat_map(&(&1["options"] || [])) |> length()
    per_option = if option_count > 0, do: div(delay_for(index, ctx), option_count), else: 0

    for q <- questions do
      puts([
        ANSI.cyan(),
        "  │ ",
        ANSI.bright(),
        ANSI.white(),
        to_string(q["header"] || ""),
        ANSI.reset(),
        ANSI.white(),
        "  ",
        to_string(q["question"] || ""),
        ANSI.reset()
      ])

      for o <- q["options"] || [], do: render_option(o, per_option)
    end
  end

  # -- tool action: render Claude-Code style + fire the real op -------------
  defp render_block(%{"type" => "tool_use"} = block, _type, index, ctx) do
    tool_call = block |> ToolCall.new() |> inject_session_id(ctx)
    puts([ANSI.cyan(), "⏺ ", action_label(tool_call), ANSI.reset()])
    Replayer.fire(tool_call, ctx)
    beat(delay_for(index, ctx))
  end

  # -- recorded tool result -------------------------------------------------
  defp render_block(%{"type" => "tool_result"} = block, _type, index, ctx) do
    text = block |> result_text() |> String.trim()

    if text != "" do
      render_result(text)
      beat(delay_for(index, ctx))
    end
  end

  defp render_block(_block, _type, _index, _ctx), do: :ok

  # One option: its label, its wrapped description, and the beat after it.
  #
  # Split out of the clause above, which was one point over the complexity
  # limit. It is also the unit the pacing is about — `per_option` exists so the
  # options arrive one at a time, and that is easier to see with the thing being
  # paced named.
  defp render_option(option, per_option) do
    puts([
      ANSI.cyan(),
      "  │   ",
      ANSI.yellow(),
      "○ ",
      to_string(option["label"] || ""),
      ANSI.reset()
    ])

    option["description"]
    |> wrap(@option_width)
    |> Enum.take(@option_desc_lines)
    |> Enum.each(fn line ->
      puts([ANSI.cyan(), "  │     ", ANSI.faint(), line, ANSI.reset()])
    end)

    beat(per_option)
  end

  # Most results are noise past the first line. An answer block is the
  # exception — it is one line per question, and the answers are the point.
  defp render_result(text) do
    if answer_block?(text) do
      lines = text |> String.split("\n", trim: true) |> Enum.take(@answer_cap)

      for {line, i} <- Enum.with_index(lines) do
        prefix = if i == 0, do: "  ⎿  ", else: "     "
        colour = if i == 0, do: ANSI.faint(), else: ANSI.green()
        puts([colour, prefix, cap(String.trim(line), @result_cap), ANSI.reset()])
      end
    else
      puts([ANSI.faint(), "  ⎿  ", cap(first_line(text), @result_cap), ANSI.reset()])
    end
  end

  defp answer_block?(text) do
    String.contains?(text, "The user answered") and String.contains?(text, "\n")
  end

  # Greedy word wrap. Long unbroken tokens (a hex colour, a path) are left to
  # overflow rather than be chopped mid-token.
  defp wrap(nil, _width), do: []

  defp wrap(text, width) do
    text
    |> to_string()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce([], &add_word(&1, &2, width))
    |> Enum.reverse()
  end

  # One word onto the accumulator: onto the current line if it fits, otherwise
  # starting a new one. Lifted out of the fold, where the `case`-inside-`reduce`
  # -inside-`if` was three levels deep for a two-way decision.
  defp add_word(word, [], _width), do: [word]

  defp add_word(word, [current | rest], width) do
    if String.length(current) + 1 + String.length(word) <= width,
      do: [current <> " " <> word | rest],
      else: [word, current | rest]
  end

  # Task/QA tools (start_task, evaluate_task, submit_qa_result, create_issue,
  # accept_issue, resolve_issue, …) expect a `session_id` arg that the
  # PreToolUse hook injects at record time. The transcript's recorded input
  # doesn't carry it, so we inject from the harness Session we seeded at
  # play start. Tools that don't read it ignore it.
  defp inject_session_id(%ToolCall{name: @harness_prefix <> _, input: input} = tc, %{
         session_id: sid
       })
       when is_binary(sid) do
    %{tc | input: Map.put_new(input || %{}, "session_id", sid)}
  end

  defp inject_session_id(tool_call, _ctx), do: tool_call

  # Housekeeping slash commands. These really are noise in a demo — nobody
  # needs to watch a context get cleared.
  @housekeeping ~w(/clear /compact /cost /model /help /exit /login /logout /doctor /status)

  # Local-command metadata Claude Code injects as user text. Most of it is
  # noise, but the invocation itself is not: a video that says "run one
  # command" has to show the command. Dropping it wholesale meant the most
  # important frame of a demo never rendered.
  defp command_noise?(text) do
    # The payload a skill injects when it loads: its base directory and the
    # whole prompt as JSON. Machine scaffolding, not something anyone said.
    String.starts_with?(text, "Base directory for this skill:") or
      String.contains?(text, "<local-command-caveat>") or
      (command_invocation(text) == nil and
         (String.contains?(text, "<command-name>") or
            String.contains?(text, "<command-message>") or
            String.starts_with?(text, "<command-")))
  end

  # `/codemyspec:design ui` out of the <command-name>/<command-args> pair.
  # Returns nil for housekeeping commands and for anything unparseable, both of
  # which fall through to being filtered.
  defp command_invocation(text) do
    with [_, name] <- Regex.run(~r{<command-name>([^<]+)</command-name>}, text),
         name = String.trim(name),
         false <- name in @housekeeping do
      args =
        case Regex.run(~r{<command-args>([^<]*)</command-args>}, text) do
          [_, a] -> String.trim(a)
          _ -> ""
        end

      String.trim("#{name} #{args}")
    else
      _ -> nil
    end
  end

  # -- action labels (Claude Code-ish) --------------------------------------
  defp action_label(%ToolCall{name: "Bash", input: i}),
    do: "Bash(#{first_line(i["command"] || "")})"

  defp action_label(%ToolCall{name: "Write", input: i}), do: "Write(#{rel(i["file_path"])})"
  defp action_label(%ToolCall{name: "Edit", input: i}), do: "Edit(#{rel(i["file_path"])})"
  defp action_label(%ToolCall{name: "Read", input: i}), do: "Read(#{rel(i["file_path"])})"

  defp action_label(%ToolCall{name: @harness_prefix <> tool, input: i}),
    do: "#{tool}(#{args(i)})"

  defp action_label(%ToolCall{name: "mcp__" <> rest}),
    do: rest |> String.split("__") |> List.last()

  defp action_label(%ToolCall{name: name}), do: name

  defp args(input) when is_map(input) do
    input
    |> Map.take([
      "story_id",
      "title",
      "statement",
      "requirement_name",
      "path",
      "name",
      "component_name"
    ])
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{cap(to_string(v), 48)}" end)
  end

  defp args(_), do: ""

  # -- helpers --------------------------------------------------------------
  defp result_text(%{"content" => content}) when is_list(content),
    do:
      content
      |> Enum.map(fn b -> is_map(b) && b["text"] end)
      |> Enum.filter(& &1)
      |> Enum.join(" ")

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

  # Pacing schedule: a sorted list of {from_index, delay_ms} breakpoints. The
  # active delay is the one from the latest breakpoint whose from_index <= the
  # current entry index. Lets one continuous playback fast-forward through
  # plumbing and slow on money beats — no video cuts needed.
  defp normalize_pacing(nil, base_delay), do: [{0, base_delay}]

  defp normalize_pacing(list, _base) when is_list(list) do
    list |> Enum.map(fn {from, d} -> {from, d} end) |> Enum.sort_by(&elem(&1, 0))
  end

  defp normalize_pacing(str, _base) when is_binary(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(fn pair ->
      [from, d] = String.split(pair, ":", parts: 2)
      {String.to_integer(String.trim(from)), String.to_integer(String.trim(d))}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp delay_for(index, %{pacing: schedule}) do
    schedule
    |> Enum.reduce({0, 0}, fn {from, d}, acc -> if from <= index, do: {from, d}, else: acc end)
    |> elem(1)
  end

  # Seed a harness Session whose external_conversation_id matches the
  # transcript's session UUID, so the task/QA tools' resolve_session lookup
  # succeeds when we inject session_id into their args.
  defp seed_session(transcript, opts) do
    with mcp_url when is_binary(mcp_url) <- opts[:mcp_url],
         sid when is_binary(sid) <- first_session_id(transcript) do
      base = String.replace_suffix(mcp_url, "/mcp", "")
      url = base <> "/api/hooks/session-start"
      target = opts[:target_dir] || "/tmp/cms_demo_mms"

      # The target's own harness id, from `.cms_harness.json`. Sending the
      # directory instead had the server walk up to a `mix.exs` to find a
      # checkout, which is how a demo replay could seed a session against a
      # neighbouring one.
      headers = [
        {"x-harness-id", Replayer.working_copy_id(target) || ""},
        {"content-type", "application/json"}
      ]

      case Req.post(url, json: %{session_id: sid}, headers: headers, receive_timeout: 10_000) do
        {:ok, %{status: 200}} ->
          sid

        {:ok, %{status: status, body: body}} ->
          IO.puts(:stderr, "  ! session-start http #{status}: #{inspect(body)}")
          sid

        {:error, e} ->
          IO.puts(:stderr, "  ! session-start error: #{Exception.message(e)}")
          sid
      end
    else
      _ -> nil
    end
  end

  defp first_session_id(transcript) do
    Enum.find_value(transcript.entries, fn e -> e.session_id end)
  end
end
