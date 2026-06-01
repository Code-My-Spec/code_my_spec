defmodule CodeMySpec.Transcripts.Replayer do
  @moduledoc """
  Replays tool calls from a Claude Code transcript onto a target directory and,
  optionally, against a running local harness over MCP.

  Two surfaces are reconstructed, in the transcript's chronological order:

    * **Filesystem** — Write, Edit, and select Bash (`mkdir -p`, `mv`) operations
      are applied to `target_dir`, with absolute paths rewritten from the
      recorded working directory.
    * **Harness DB / UI** — `mcp__plugin_codemyspec_local__*` calls are re-issued
      to the harness MCP endpoint (`:mcp_url`) scoped to `target_dir` via the
      `X-Working-Dir` header. When `:mcp_url` is nil these are skipped (pure
      filesystem replay, the original behaviour).

  Everything else (Read, Task, WebFetch, marketing MCP, vibium, networked Bash)
  is skipped. Operations never halt the run: failures are caught, tallied, and
  returned in the `Result` so a long replay can be curated after the fact.
  """

  alias CodeMySpec.Transcripts
  alias CodeMySpec.Transcripts.ClaudeCode.ToolCall

  @harness_prefix "mcp__plugin_codemyspec_local__"

  defmodule Result do
    @moduledoc "Tally of a replay run."
    defstruct file: 0, skip: 0, mcp_ok: 0, mcp_err: 0, error: 0, total: 0, failures: []

    @type t :: %__MODULE__{
            file: non_neg_integer(),
            skip: non_neg_integer(),
            mcp_ok: non_neg_integer(),
            mcp_err: non_neg_integer(),
            error: non_neg_integer(),
            total: non_neg_integer(),
            failures: [{String.t(), String.t()}]
          }
  end

  @doc """
  Replays operations from a transcript file.

  ## Options

    - `:mcp_url` - harness MCP endpoint (e.g. `"http://localhost:4005/mcp"`).
      When nil, harness calls are skipped.
    - `:source_cwd` - override the recorded cwd for path rewriting.
    - `:log` - `:quiet`, `:errors` (default), or `:all`.

  Returns `{:ok, %Result{}}` or `{:error, term()}` if the transcript can't be
  parsed or no cwd can be resolved.
  """
  @spec replay(Path.t(), Path.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def replay(transcript_path, target_dir, opts \\ []) do
    with {:ok, transcript} <- Transcripts.parse(transcript_path),
         {:ok, source_cwd} <- resolve_cwd(transcript, opts) do
      {:ok, replay_operations(transcript, source_cwd, target_dir, opts)}
    end
  end

  @doc "Replays operations from an already-parsed transcript."
  @spec replay_transcript(Transcripts.ClaudeCode.Transcript.t(), Path.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def replay_transcript(transcript, target_dir, opts \\ []) do
    with {:ok, source_cwd} <- resolve_cwd(transcript, opts) do
      {:ok, replay_operations(transcript, source_cwd, target_dir, opts)}
    end
  end

  defp replay_operations(transcript, source_cwd, target_dir, opts) do
    ctx = %{
      source_cwd: source_cwd,
      target_dir: target_dir,
      mcp_url: Keyword.get(opts, :mcp_url),
      log: Keyword.get(opts, :log, :errors),
      delay_ms: Keyword.get(opts, :delay_ms, 0)
    }

    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to)

    transcript
    |> Transcripts.get_tool_calls()
    |> Enum.with_index()
    |> Enum.filter(fn {_tc, i} -> i >= from and (is_nil(to) or i < to) end)
    |> Enum.reduce(%Result{}, fn {tool_call, i}, acc -> step(tool_call, i, ctx, acc) end)
  end

  @doc """
  Apply a single tool call against the filesystem / harness and return the
  outcome (`{:ok, :file | :mcp_ok | :skip}` or `{:mcp_err | :error, reason}`).

  Public so the terminal `Player` can fire state-changing ops from its own
  entry-walking loop while it renders. `ctx` needs `:source_cwd`, `:target_dir`,
  and (optionally) `:mcp_url`.
  """
  @spec fire(ToolCall.t(), map()) :: tuple()
  def fire(%ToolCall{} = tool_call, ctx) do
    safe_apply(tool_call, Map.put_new(ctx, :mcp_url, nil))
  end

  defp step(%ToolCall{} = tool_call, index, ctx, acc) do
    outcome = safe_apply(tool_call, ctx)
    log(ctx, tool_call, index, outcome)
    pace(ctx, outcome)
    tally(acc, tool_call, outcome)
  end

  # Pacing for live playback — sleep after each visible op (not skips) so the
  # web UI animates at a watchable speed. delay_ms: 0 replays as fast as possible.
  defp pace(%{delay_ms: ms}, outcome) when ms > 0 do
    case outcome do
      {:ok, :skip} -> :ok
      _ -> Process.sleep(ms)
    end
  end

  defp pace(_ctx, _outcome), do: :ok

  defp safe_apply(tool_call, ctx) do
    apply_operation(tool_call, ctx)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- Write: create/overwrite a file

  defp apply_operation(%ToolCall{name: "Write", input: input}, ctx) do
    path = rewrite_path(input["file_path"], ctx)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, input["content"] || "")
    {:ok, :file}
  end

  # -- Edit: replace first occurrence of old_string with new_string

  defp apply_operation(%ToolCall{name: "Edit", input: input}, ctx) do
    path = rewrite_path(input["file_path"], ctx)
    content = File.read!(path)
    new_content = String.replace(content, input["old_string"], input["new_string"], global: false)
    File.write!(path, new_content)
    {:ok, :file}
  end

  # -- Bash: only replay deterministic filesystem commands (mkdir -p, mv)

  defp apply_operation(%ToolCall{name: "Bash", input: input}, ctx) do
    command = input["command"] || ""

    cond do
      mkdir_command?(command) -> apply_mkdir(command, ctx)
      mv_command?(command) -> apply_mv(command, ctx)
      true -> {:ok, :skip}
    end
  end

  # -- Harness MCP: re-issue against the running local harness

  defp apply_operation(
         %ToolCall{name: @harness_prefix <> tool, input: input},
         %{mcp_url: url} = ctx
       )
       when is_binary(url) do
    dispatch_mcp(tool, input || %{}, ctx)
  end

  # -- Everything else (incl. harness calls when mcp_url is nil): skip

  defp apply_operation(%ToolCall{}, _ctx), do: {:ok, :skip}

  # -- Bash helpers ---------------------------------------------------------

  defp mkdir_command?(command), do: String.starts_with?(String.trim(command), "mkdir -p ")

  defp apply_mkdir(command, ctx) do
    command
    |> String.trim()
    |> String.replace_prefix("mkdir -p ", "")
    |> String.split()
    |> Enum.each(fn path -> File.mkdir_p!(rewrite_path(path, ctx)) end)

    {:ok, :file}
  end

  defp mv_command?(command) do
    trimmed = String.trim(command)
    String.starts_with?(trimmed, "mv ") and not String.contains?(trimmed, "|")
  end

  defp apply_mv(command, ctx) do
    case command |> String.trim() |> String.replace_prefix("mv ", "") |> String.split() do
      [source, dest] ->
        rewritten_source = rewrite_path(source, ctx)
        rewritten_dest = rewrite_path(dest, ctx)
        File.mkdir_p!(Path.dirname(rewritten_dest))
        File.rename!(rewritten_source, rewritten_dest)
        {:ok, :file}

      _ ->
        {:ok, :skip}
    end
  end

  # -- MCP dispatch ---------------------------------------------------------

  defp dispatch_mcp(tool, arguments, ctx) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{name: tool, arguments: arguments}
    }

    headers = [
      {"x-working-dir", ctx.target_dir},
      {"accept", "application/json, text/event-stream"}
    ]

    case Req.post(ctx.mcp_url, json: body, headers: headers, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: raw}} -> interpret_mcp(raw)
      {:ok, %{status: status}} -> {:mcp_err, "http #{status}"}
      {:error, exception} -> {:mcp_err, Exception.message(exception)}
    end
  end

  # Streamable-HTTP responses arrive as SSE text; Req hands back the raw body.
  defp interpret_mcp(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map(fn line -> line |> String.replace_prefix("data:", "") |> String.trim() end)
    |> Enum.find_value({:mcp_err, "no data frame"}, &decode_frame/1)
  end

  defp interpret_mcp(body) when is_map(body), do: interpret_decoded(body)

  defp decode_frame(data) do
    case Jason.decode(data) do
      {:ok, decoded} -> interpret_decoded(decoded)
      _ -> nil
    end
  end

  defp interpret_decoded(%{"result" => %{"isError" => true} = result}),
    do: {:mcp_err, result_text(result)}

  defp interpret_decoded(%{"result" => _}), do: {:ok, :mcp_ok}
  defp interpret_decoded(%{"error" => error}), do: {:mcp_err, inspect(error)}
  defp interpret_decoded(_), do: {:mcp_err, "unexpected response"}

  defp result_text(%{"content" => [%{"text" => text} | _]}), do: String.slice(text, 0, 160)
  defp result_text(other), do: other |> inspect() |> String.slice(0, 160)

  # -- Path rewriting -------------------------------------------------------

  defp rewrite_path(nil, _ctx), do: raise(ArgumentError, "nil file_path")
  defp rewrite_path(path, ctx), do: String.replace(path, ctx.source_cwd, ctx.target_dir)

  defp resolve_cwd(transcript, opts) do
    case Keyword.get(opts, :source_cwd) do
      nil -> extract_cwd(transcript)
      cwd -> {:ok, cwd}
    end
  end

  defp extract_cwd(transcript) do
    case Enum.find(transcript.entries, &(&1.cwd != nil)) do
      nil -> {:error, :no_cwd_found}
      entry -> {:ok, entry.cwd}
    end
  end

  # -- Tally + logging ------------------------------------------------------

  defp tally(acc, _tc, {:ok, :file}), do: bump(acc, :file)
  defp tally(acc, _tc, {:ok, :skip}), do: bump(acc, :skip)
  defp tally(acc, _tc, {:ok, :mcp_ok}), do: bump(acc, :mcp_ok)

  defp tally(acc, tc, {:mcp_err, reason}),
    do: acc |> bump(:mcp_err) |> add_failure(tc, reason)

  defp tally(acc, tc, {:error, reason}),
    do: acc |> bump(:error) |> add_failure(tc, reason)

  defp bump(acc, key),
    do: %{acc | key => Map.fetch!(acc, key) + 1, total: acc.total + 1}

  defp add_failure(acc, %ToolCall{name: name}, reason),
    do: %{acc | failures: [{name, to_string(reason)} | acc.failures]}

  defp log(%{log: :quiet}, _tc, _index, _outcome), do: :ok

  defp log(%{log: :errors}, %ToolCall{name: name}, index, {tag, reason})
       when tag in [:mcp_err, :error],
       do: IO.puts(:stderr, "  [#{index}] ✗ #{name}: #{reason}")

  defp log(%{log: :errors}, _tc, _index, _outcome), do: :ok

  defp log(%{log: :all}, %ToolCall{name: name}, index, outcome),
    do: IO.puts(:stderr, "  [#{index}] #{format_outcome(outcome)} #{short(name)}")

  defp short(@harness_prefix <> tool), do: tool
  defp short(name), do: name

  defp format_outcome({:ok, :mcp_ok}), do: "→"
  defp format_outcome({:ok, :file}), do: "✎"
  defp format_outcome({:ok, :skip}), do: "·"
  defp format_outcome({tag, _}) when tag in [:mcp_err, :error], do: "✗"
end
