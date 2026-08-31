defmodule CodeMySpec.McpServers.CodeMode do
  @moduledoc """
  Builds the catalog `CodeMySpec.CodeMode` runs scripts against.

  This is the half that knows about MCP: which tools are registered, how to
  build a frame, and how to read a `Response`. `CodeMode` itself knows none of
  it — Boundary saw to that, and it is why the runtime's tests need two fake
  tools rather than a server.

  The registrations come from `ScriptableTools`, not `LocalServer`. Story 971
  took the long tail off the advertised list, and taking them off `LocalServer`
  alone would have taken them away from scripts too — unregistered is
  unreachable, not merely unadvertised.

  ## Scope is captured here

  The catalog is built per call, closing over the scope of the agent that sent
  the script. That is the whole of "a script acts with exactly the authority of
  the agent that sent it": every binding is already bound to a frame before the
  VM exists, and nothing a script can write reaches it.

  ## What a script actually receives

  Data from a tool that implements `ScriptResult.script_result/2`, and the
  tool's prose from one that does not.

  The prose fallback is not a degraded mode; it is what every tool gave scripts
  before that callback existed. What it cannot do is be iterated — a formatted
  listing is a string — so composing over a result is exactly what opting in
  buys.

  Deliberately **not** `structured_content`. Anubis can put structured data on
  the wire, and Claude then ignores the text beside it — measured, and the
  reason every tool here answers with prose alone. Serving scripts that way
  would make every direct tool call pay for it. The script path is separate and
  a direct caller never sees it.
  """

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.ScriptableTools
  alias CodeMySpec.McpServers.ScriptResult

  @doc "The catalog of tools a script may call, acting as `scope`."
  @spec catalog(term()) :: Catalog.t()
  def catalog(scope), do: catalog(scope, nil)

  @doc """
  The same, scoped to what one agent may call.

  `allowed` is the list on the agent's row — not its role. See
  `CodeMySpec.Agents.ToolSets`.
  """
  @spec catalog(Scope.t(), [String.t()] | nil) :: Catalog.t()
  def catalog(scope, allowed) do
    Catalog.from(ScriptableTools.__components__(), &invoker(&1, scope), allowed)
  end

  @doc "What this agent may not call, of the tools that exist."
  @spec out_of_scope([String.t()] | nil) :: [String.t()]
  def out_of_scope(allowed), do: Catalog.out_of_scope(ScriptableTools.__components__(), allowed)

  defp invoker(tool, scope) do
    frame = %Frame{assigns: %{current_scope: scope}}

    fn args ->
      with {:ok, params} <- validate(tool, args) do
        execute(tool, params, frame)
      end
    end
  end

  # The same casting a real MCP call goes through. Skipping it would make a
  # script a second, laxer door onto the same tools, and the casting is
  # load-bearing besides — the schema is what turns a Lua number into the
  # integer a tool expects.
  defp validate(%{validate_input: validate}, args) when is_function(validate, 1) do
    case validate.(args) do
      {:ok, params} -> {:ok, params}
      {:error, reason} -> {:error, "invalid arguments: #{describe(reason)}"}
    end
  end

  defp validate(_tool, args), do: {:ok, args}

  # Data when the tool can give it, prose when it cannot. The fallback is not a
  # degraded mode — it is what every tool gave scripts before `script_result/2`
  # existed, and most still do.
  defp execute(tool, params, frame) do
    case ScriptResult.implemented?(tool.handler) do
      true -> script_result(tool, params, frame)
      false -> reply(tool, params, frame)
    end
  end

  defp script_result(tool, params, frame) do
    case tool.handler.script_result(params, frame) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp reply(tool, params, frame) do
    case tool.handler.execute(params, frame) do
      {:reply, response, _frame} -> read(response)
      {:error, reason, _frame} -> {:error, describe(reason)}
      other -> {:error, "unexpected reply from #{tool.name}: #{inspect(other)}"}
    end
  end

  # `isError` is the tool saying it could not do the thing, which is a `nil,
  # err` pair in the script rather than a crash — the script decides whether
  # that ends its work.
  defp read(%Response{isError: true} = response), do: {:error, text(response)}
  defp read(%Response{structured_content: nil} = response), do: {:ok, text(response)}
  defp read(%Response{structured_content: structured}), do: {:ok, structured}

  defp text(%Response{} = response) do
    response
    |> Response.to_protocol()
    |> Map.get("content", [])
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp describe(reason) when is_binary(reason), do: reason

  # Validation errors arrive as structs carrying a readable sentence and a lot
  # of machinery around it. `inspect/1` on the struct puts the machinery in the
  # agent's context and buries the sentence — and in a loop, twenty times. Pull
  # the sentence out, name the field, drop the rest.
  defp describe(errors) when is_list(errors) do
    case Enum.map(errors, &describe/1) do
      [] -> "invalid"
      described -> Enum.join(described, "; ")
    end
  end

  defp describe(%{message: message} = error) when is_binary(message) do
    case field(error) do
      nil -> message
      name -> "#{name} #{message}"
    end
  end

  defp describe(reason), do: inspect(reason)

  defp field(%{path: [name | _rest]}), do: name
  defp field(%{key: name}) when not is_nil(name), do: name
  defp field(_error), do: nil
end
