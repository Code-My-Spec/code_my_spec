defmodule CodeMySpec.McpServers.ScriptResult do
  @moduledoc """
  A tool's result as data, for a script rather than for a reader.

  ## Why not `structured_content`

  Anubis already has a way to attach structured data to a response, and using
  it here would be wrong. `Response.structured/2` puts `structuredContent` on
  the wire, and **Claude ignores the text when it is present** — measured, and
  the reason every tool in this codebase answers with prose alone. Adding it to
  serve scripts would regress every direct tool call to pay for it.

  So the script path is separate and never reaches a direct caller. A tool that
  implements `script_result/2` hands records to `run_script`; the same tool's
  `execute/2` keeps answering a human-shaped MCP call with exactly the prose it
  did before. Neither knows about the other.

  ## Implementing it without a second code path

  The data already exists inside `execute/2` before it is formatted. Lift that
  into a function and call it from both:

      def execute(params, frame) do
        case data(params, frame) do
          {:ok, titles} -> {:reply, Mapper.story_titles_response(titles), frame}
          {:error, reason} -> {:reply, Mapper.error(reason), frame}
        end
      end

      @impl CodeMySpec.McpServers.ScriptResult
      def script_result(params, frame), do: data(params, frame)

  A tool that does not implement it is not broken — `run_script` falls back to
  the prose, which is what every tool gave scripts before this existed. That is
  the whole migration story: opt in where composing over the result is worth
  something, leave the rest.

  ## Shape

  Plain maps and lists with string keys, JSON-encodable. They cross into a Lua
  VM, where an Ecto struct or an atom key is not a thing that exists.
  """

  @doc """
  The tool's result as data, or why it could not produce one.

  `{:error, message}` reaches the script as Lua's `nil, err` pair, the same as
  any other refusal.
  """
  @callback script_result(params :: map(), frame :: term()) ::
              {:ok, term()} | {:error, String.t() | atom()}

  @doc "Whether this tool can answer a script with data."
  @spec implemented?(module()) :: boolean()
  def implemented?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :script_result, 2)
  end

  def implemented?(_module), do: false
end
