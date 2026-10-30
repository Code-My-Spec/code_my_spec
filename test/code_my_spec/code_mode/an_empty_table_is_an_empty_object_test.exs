defmodule CodeMySpec.CodeMode.AnEmptyTableIsAnEmptyObjectTest do
  @moduledoc """
  Issue f281ba34: `call_mcp_server` with `arguments = {}` was refused before it
  ran ("arguments expected a nested schema but received schema: :map"). Lua
  has one table type, so `{}` decodes as an empty list; where the tool's
  schema wants an object, it is an empty object.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog
  alias CodeMySpec.Qa.Tools.CallMcpServer
  alias CodeMySpec.Tools

  # call_mcp_server's own schema, validated as a real call is; it answers
  # what reached it instead of connecting anywhere.
  defp catalog do
    Catalog.from(
      [
        %{
          name: "call_mcp_server",
          description: "Probes an MCP server.",
          input_schema: Tools.input_schema(CallMcpServer),
          invoke: &answer(Tools.validate(CallMcpServer, &1))
        }
      ],
      fn tool -> Map.fetch!(tool, :invoke) end
    )
  end

  defp answer({:ok, params}), do: {:ok, params}
  defp answer({:error, errors}), do: {:invalid_call, inspect(errors)}

  defp run(call) do
    result = CodeMode.eval(catalog(), "return call_mcp_server(#{call})")
    refute CodeMode.Result.failed?(result), inspect(result)
    result
  end

  test "an empty arguments table reaches the tool as an empty object" do
    run(~S|{ url = "http://localhost:4004", tool = "get_next_requirement", arguments = {} }|)
  end

  test "an empty headers table does too" do
    run(~S|{ url = "http://localhost:4004", headers = {}, arguments = {} }|)
  end

  test "arguments with a script, and arguments left out, still reach it" do
    run(
      ~S|{ url = "http://localhost:4004", tool = "run_script", arguments = { script = "return 1" } }|
    )

    run(~S|{ url = "http://localhost:4004", tool = "list_stories" }|)
  end
end
