defmodule CodeMySpec.McpServers.CodeMode do
  @moduledoc """
  Builds the catalog `CodeMySpec.CodeMode` runs scripts against.

  This is the half that knows about MCP: which tools the server registers, how
  to build a frame, and how to read a `Response`. `CodeMode` itself knows none
  of it — Boundary saw to that, and it is why the runtime's tests need two fake
  tools rather than a server.

  ## Scope is captured here

  The catalog is built per call, closing over the scope of the agent that sent
  the script. That is the whole of "a script acts with exactly the authority of
  the agent that sent it": every binding is already bound to a frame before the
  VM exists, and nothing a script can write reaches it.

  ## What a script actually receives

  Our tools answer with prose — `Response.text/2` — because
  `structured_content` alongside text makes Claude ignore the text. In a script
  that is a real limit: `list_stories()` returns a formatted listing, not a
  list, so a script can sequence and branch on tool calls but cannot iterate
  their results as records.

  Structured content is preferred when a tool sets it, so the seam is here at
  no cost and a tool that opts in becomes scriptable as data without changing
  anything below. Nothing sets it today. Making the flagship
  "list, filter, count" shape work is a per-tool decision that has to revisit
  why text-only was chosen, and it is not this story.
  """

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.McpServers.LocalServer

  @doc "The catalog of tools a script may call, acting as `scope`."
  @spec catalog(term()) :: Catalog.t()
  def catalog(scope) do
    Catalog.from(LocalServer.__components__(), &invoker(&1, scope))
  end

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

  defp execute(tool, params, frame) do
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
  defp describe(reason), do: inspect(reason)
end
