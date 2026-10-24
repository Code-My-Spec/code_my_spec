defmodule CodeMySpec.CodeMode do
  @moduledoc """
  Running an agent's script against the harness's tools, and the documentation
  it looks them up in.

  ## Two entry points

  `eval/3` runs a script with the catalog's tools bound as Lua functions.
  `docs/2` answers what a tool takes, on demand, so the arguments are looked up
  instead of carried.

  ## The catalog is handed in

  Both take a `Catalog`, built by the MCP layer from the server's registrations.
  Nothing under `CodeMode` references Anubis or the server (`McpServers`
  depends on `CodeMySpec`, not the reverse), so the runtime is tested with fake
  tools rather than a server.

  ## What it guarantees

  A script cannot reach the host, cannot run forever, cannot build an answer
  too big to carry, and acts with exactly the authority of the agent that sent
  it. See `CodeMySpec.CodeMode.Sandbox` for how each of those is bounded, and
  `cap/1` for what bounds the answer it returns.

  Adapted from Omni Tools and the AshLua "code mode" pattern (Apache-2.0 and
  MIT respectively). Design: `.code_my_spec/knowledge/tools/index.md`; original
  research: `.code_my_spec/knowledge/code_mode/lua_for_mcp.md`.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  alias CodeMySpec.CodeMode.{Bindings, Catalog, Docs, LuaValue, Result, Sandbox}

  @doc """
  Runs `script` with `catalog`'s tools bound, and answers with a `Result`.

  Never raises for anything the script did. A syntax error, a broken limit, a
  crashed tool and a timeout are all results with an `error` on them, because
  the caller is an MCP tool answering an agent — and an agent can act on
  "instruction budget exceeded" but not on a transport failure.
  """
  @spec eval(Catalog.t(), String.t(), keyword()) :: Result.t()
  def eval(catalog, script, opts \\ []) when is_binary(script) do
    fn -> run(catalog, script, opts) end
    |> Sandbox.with_timeout(opts)
    |> interpret()
  end

  # Big enough for a real answer, small enough that one reply cannot swamp the
  # agent's context.
  @max_answer_bytes 24_000

  @doc "The largest answer a caller should hand back, in bytes."
  @spec max_answer_bytes() :: pos_integer()
  def max_answer_bytes, do: @max_answer_bytes

  @doc """
  Cuts a rendered answer to `max_answer_bytes/0`, and says it did.

  The one cap for every caller that renders a script's answer. The sandbox
  bounds what a script may *build*, not what it may *return*. The truncation
  note is part of the contract: a silent cut lets the agent reason about a
  fragment as if it were the whole answer.

  `opts[:spill_label]`, when given, names the caller (e.g. "run_script") so
  a cut answer's full content is written to disk instead of simply
  discarded (41bdee7d), with the note naming the path and the full size
  instead of just the byte count. This assumes the caller and the file this
  writes land on the same machine -- true for every deployment this runs in
  today, where a working copy's own server and harness share one
  filesystem. A caller for which that would not hold should omit it and
  get today's plain note instead of a path nothing downstream can read.
  """
  @spec cap(String.t(), keyword()) :: String.t()
  def cap(text, opts \\ [])

  def cap(text, _opts) when is_binary(text) and byte_size(text) <= @max_answer_bytes,
    do: sanitize_utf8(text)

  def cap(text, opts) when is_binary(text) do
    sanitized = sanitize_utf8(text)
    note = truncation_note(sanitized, opts)

    # A byte cut can split a multi-byte character; invalid UTF-8 then fails in
    # the JSON encoder and the answer is lost entirely. Trimming back (never
    # growing) is what keeps this within the byte budget the note's own size
    # was computed against (6880b4ab).
    sanitized
    |> binary_part(0, @max_answer_bytes - byte_size(note))
    |> trim_to_valid_utf8()
    |> Kernel.<>(note)
  end

  defp truncation_note(full_text, opts) do
    with label when is_binary(label) <- Keyword.get(opts, :spill_label),
         {:ok, path} <- spill(label, full_text) do
      "\n\n[truncated at #{@max_answer_bytes} characters -- the full answer " <>
        "(#{byte_size(full_text)} bytes) was written to #{path}]"
    else
      _ -> "\n\n[truncated — the answer was longer than #{@max_answer_bytes} characters]"
    end
  end

  defp spill(label, content) do
    dir = spill_dir()
    prune_spilled(dir)
    path = Path.join(dir, "#{label}-#{System.unique_integer([:positive])}.txt")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp spill_dir do
    Application.get_env(:code_my_spec, :code_mode_spill_dir) ||
      Path.join([System.user_home!(), ".codemyspec", "code_mode_spill"])
  end

  # A day: generous enough that an agent coming back to a path from an
  # earlier turn still finds it, short enough that these do not accumulate
  # forever on a machine nobody is watching.
  @spill_max_age_seconds 24 * 60 * 60

  defp prune_spilled(dir) do
    cutoff = System.os_time(:second) - @spill_max_age_seconds

    for name <- ls(dir),
        path = Path.join(dir, name),
        match?({:ok, %{mtime: mtime}} when mtime < cutoff, File.stat(path, time: :posix)) do
      File.rm(path)
    end

    :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _} -> []
    end
  end

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      case binary do
        <<>> -> <<>>
        _ -> binary |> binary_part(0, byte_size(binary) - 1) |> trim_to_valid_utf8()
      end
    end
  end

  # Invalid UTF-8 crashes the MCP session outright, not the single call: the
  # vendored session's own JSON.encode! has no rescue around it, so a result
  # that merely contains a bad byte -- already in stored content a tool simply
  # rendered (get_issue, get_story), not from any cut here -- takes the whole
  # session down with it (6880b4ab). No byte budget is at stake on this path
  # (the text already fit before this call), so replacing just the offending
  # byte with the standard replacement character is the right trade: every
  # valid stretch survives verbatim, instead of mass-trimming everything from
  # the bad byte to the end of the string the way `trim_to_valid_utf8/1`
  # above would.
  defp sanitize_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      replace_invalid_utf8(binary, [])
    end
  end

  @replacement_char <<0xEF, 0xBF, 0xBD>>

  defp replace_invalid_utf8(binary, acc) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      valid when is_binary(valid) ->
        IO.iodata_to_binary(Enum.reverse([valid | acc]))

      {:error, good, <<_bad_byte, rest::binary>>} ->
        replace_invalid_utf8(rest, [@replacement_char, good | acc])

      {:error, good, <<>>} ->
        IO.iodata_to_binary(Enum.reverse([good | acc]))

      {:incomplete, good, _rest} ->
        IO.iodata_to_binary(Enum.reverse([@replacement_char, good | acc]))
    end
  end

  @doc """
  Documentation for the catalog, on demand.

  With no options, the index — every tool name and its first line. With
  `name:`, that one tool in full. With `search:`, the ones matching, ranked.
  """
  @spec docs(Catalog.t(), keyword()) :: String.t()
  defdelegate docs(catalog, opts \\ []), to: Docs, as: :render

  defp run(catalog, script, opts) do
    lua =
      opts
      |> Sandbox.new()
      |> Bindings.install(
        catalog,
        Keyword.get(opts, :out_of_scope, []),
        Keyword.get(opts, :agent_kind),
        Keyword.get(opts, :carried, :all),
        # Every tool on the server, so a name belonging to another role is told
        # apart from a name that belongs to nothing.
        Keyword.get(opts, :direct_names, :all)
      )

    {values, _lua} = Lua.eval!(lua, script)
    Result.ok(values |> Enum.map(&LuaValue.from_lua/1) |> value(), Bindings.printed())
  rescue
    error in Lua.CompilerException ->
      # `Exception.message/1` is deliberately the bare, ANSI-free summary
      # (Lua.CompilerException's own moduledoc says so) -- it drops the
      # location, source context and suggestion the parser already worked
      # out, which is exactly the signal an agent needs to fix a script
      # rather than guess at it (e.g. a reserved word used as a table key
      # reads only as "Expected expression" with no hint that `until` is the
      # problem). `Lua.format_exception/1` renders the richer report when
      # structured diagnostics exist, falling back to the same bare message
      # otherwise.
      Result.error(:compile, Lua.format_exception(error), Bindings.printed())

    error in Lua.RuntimeException ->
      Result.error(kind(error), explain(Exception.message(error), catalog), Bindings.printed())
  end

  # A name bound nowhere gets the remedy and, when the catalog holds something
  # close, the likely name. Runs only on a failure that already ended the script.
  # See knowledge/tools, "Refusals".
  defp explain(message, catalog) do
    case Regex.run(~r/attempt to call a nil value \(global '([^']+)'\)/, message) do
      [_, name] -> message <> did_you_mean(name, catalog)
      _ -> message
    end
  end

  defp did_you_mean(name, catalog) do
    suggestion =
      catalog
      |> Enum.map(fn {known, _} -> known end)
      |> Enum.filter(&(String.jaro_distance(&1, name) > 0.82))
      |> Enum.sort_by(&(-String.jaro_distance(&1, name)))
      |> Enum.take(3)

    case suggestion do
      [] ->
        "\n\nNo tool is bound under that name. `tool_docs({ search = \"...\" })`, " <>
          "called directly rather than from a script, lists what this machine " <>
          "actually offers — the catalog is whatever is installed here, not the " <>
          "Playwright or Puppeteer API."

      names ->
        "\n\nNo tool is bound under that name. Did you mean " <>
          Enum.map_join(names, " or ", &"`#{&1}`") <>
          "? `tool_docs({ name = \"#{hd(names)}\" })`, called directly, gives its " <>
          "arguments and a runnable example."
    end
  end

  # A script run for its writes returns `nil`, not an empty list.
  defp value([]), do: nil
  defp value([single]), do: single
  defp value(many), do: many

  # The limits raise ordinary runtime errors, so the message is the only thing
  # separating "your script is wrong" from "your script was stopped". An agent
  # retries a limit and rewrites a bug.
  defp kind(error) do
    message = Exception.message(error)

    cond do
      message =~ "instruction budget exceeded" -> :instruction_budget
      message =~ "stack overflow" -> :call_depth
      message =~ "resulting string too large" -> :result_too_large
      message =~ "is sandboxed" -> :sandboxed
      # Neither a limit nor a logic bug: one call is malformed.
      message =~ "was called wrong and did not run" -> :rejected_call
      true -> :runtime
    end
  end

  defp interpret(%Result{} = result), do: result

  defp interpret({:error, {:timeout, what}}) do
    Result.error(:timeout, "the script ran longer than it is allowed to.\n" <> what)
  end

  defp interpret({:error, {:crashed, reason}}) do
    Result.error(:crashed, "the script died: #{inspect(reason)}")
  end
end
