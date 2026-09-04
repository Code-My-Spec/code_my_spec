defmodule CodeMySpec.CodeMode do
  @moduledoc """
  Running an agent's script against the harness's tools, and the documentation
  it looks them up in.

  Story 970. An agent connecting to this harness is handed 111 tools —
  85,979 bytes, roughly 21,500 tokens, measured 2026-08-28 — and a typical task
  calls three or four of them. The rest is rent. The second cost is less
  visible: composition happens in the agent's context, so "list the stories,
  keep the ones with no criteria, count them" is three round trips plus
  arithmetic done by hand, with every intermediate list carried. In a script it
  is four lines and one call.

  ## Two entry points

  `eval/3` runs a script with the catalog's tools bound as Lua functions.
  `docs/2` answers what a tool takes, on demand, so the arguments are looked up
  instead of carried.

  ## The catalog is handed in

  Both take a `Catalog`, built by the MCP layer from the server's registrations.
  Nothing under `CodeMode` references Anubis or the server — Boundary refused
  the first version that did, correctly, since `McpServers` depends on
  `CodeMySpec` and not the other way round. The result is a runtime that is
  tested with two fake tools rather than a server.

  ## What it guarantees

  A script cannot reach the host, cannot run forever, cannot build an answer
  too big to carry, and acts with exactly the authority of the agent that sent
  it. See `CodeMySpec.CodeMode.Sandbox` for how each of those is bounded and
  why one limit does not cover another's case.

  Adapted from Omni Tools and the AshLua "code mode" pattern (Apache-2.0 and
  MIT respectively). Full research, including where their stack and ours
  differ, is in `.code_my_spec/knowledge/code_mode/lua_for_mcp.md`.
  """

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

  # Big enough for a real answer, small enough that no single one becomes the
  # turn. A browser page or an architecture dump arrives larger than everything
  # the agent was going to think about, and the saving code mode is carried for
  # is gone in one reply.
  @max_answer_bytes 24_000

  @doc "The largest answer a caller should hand back, in bytes."
  @spec max_answer_bytes() :: pos_integer()
  def max_answer_bytes, do: @max_answer_bytes

  @doc """
  Cuts a rendered answer to `max_answer_bytes/0`, and says it did.

  Here rather than in each tool because there were two callers and one cap.
  `CmsHarness.Agents.Tools.RunScript` cut at this number and said so; the
  server tool this one calls through did not, and that is the path every Claude
  Code session in a project reaches over the plugin's MCP mount. Sixty thousand
  characters asked for, sixty thousand delivered, nothing in the transcript
  saying the reply was large (b9632bba).

  The moduledoc above has promised "cannot build an answer too big to carry"
  the whole time. The sandbox bounds what a script may *build* — instruction
  budget, call depth, Lua's own string limit — and none of those bound what it
  may *return*: `string.rep("x", 60000)` breaks no limit while building.

  Cutting silently would be worse than not cutting: the agent reasons about a
  fragment as though it were the whole answer, and nothing says otherwise. So
  the note is part of the contract, not decoration.
  """
  @spec cap(String.t()) :: String.t()
  def cap(text) when is_binary(text) and byte_size(text) <= @max_answer_bytes, do: text

  def cap(text) when is_binary(text) do
    note = "\n\n[truncated — the answer was longer than #{@max_answer_bytes} characters]"

    # `binary_part/3` splits on bytes, so a cut can land inside a multi-byte
    # character and produce a binary that is no longer valid UTF-8 — which
    # travels as far as the JSON encoder and fails there, turning a large
    # answer into no answer at all.
    text
    |> binary_part(0, @max_answer_bytes - byte_size(note))
    |> trim_to_valid_utf8()
    |> Kernel.<>(note)
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
        Keyword.get(opts, :agent_kind)
      )

    {values, lua} = Lua.eval!(lua, script)
    Result.ok(values |> Enum.map(&LuaValue.from_lua/1) |> value(), Bindings.printed(lua))
  rescue
    error in Lua.CompilerException ->
      Result.error(:compile, Exception.message(error))

    error in Lua.RuntimeException ->
      Result.error(kind(error), Exception.message(error))
  end

  # A script that returns nothing is a script run for its writes, which is a
  # normal thing to do — `nil` rather than an empty list, so it reads as "no
  # answer" rather than "an answer that was a list".
  defp value([]), do: nil
  defp value([single]), do: single
  defp value(many), do: many

  # The limits raise ordinary runtime errors, so the message is the only thing
  # separating "your script is wrong" from "your script was stopped". Worth
  # separating: an agent retries a limit and rewrites a bug.
  defp kind(error) do
    message = Exception.message(error)

    cond do
      message =~ "instruction budget exceeded" -> :instruction_budget
      message =~ "stack overflow" -> :call_depth
      message =~ "resulting string too large" -> :result_too_large
      message =~ "is sandboxed" -> :sandboxed
      true -> :runtime
    end
  end

  defp interpret(%Result{} = result), do: result

  defp interpret({:error, :timeout}) do
    Result.error(
      :timeout,
      "the script ran longer than it is allowed to. A tool it called may be waiting on " <>
        "something that will not answer."
    )
  end

  defp interpret({:error, {:crashed, reason}}) do
    Result.error(:crashed, "the script died: #{inspect(reason)}")
  end
end
