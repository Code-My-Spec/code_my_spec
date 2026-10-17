defmodule CodeMySpec.McpServers.NoToolSchemaUsesTheSilentlyDroppedDocKeyTest do
  @moduledoc """
  6cb860e7: 154 tool files declared a field's documentation with `doc:`,
  which `Anubis.Server.Component`'s `field/3` macro does not recognize as
  metadata -- only `description:` is. `doc:` fell through to
  `__apply_constraints__/2`'s catch-all and was silently dropped before it
  ever reached the JSON Schema, so it was invisible everywhere: this
  project's own `tool_docs`, the raw `tools/list` response any MCP client
  sees, and Peri's own validation errors.

  Scanning the source for the key rather than calling every one of 217
  tools, because the property this guards is "nobody writes this key
  again", which a behavioural test on the tools that already got fixed
  cannot express -- the next tool added with `doc:` would pass every
  existing test and still be unrenderable.
  """

  use ExUnit.Case, async: true

  @tools_root Path.expand("../../../lib/code_my_spec/mcp_servers", __DIR__)

  test "every field, embeds_many and embeds_one call uses description:, not doc:" do
    offenders =
      @tools_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.any?(&Regex.match?(~r/(^|[^a-zA-Z_])doc:/, &1))
      end)
      |> Enum.map(&Path.relative_to(&1, @tools_root))

    assert offenders == [],
           "#{inspect(offenders)} use `doc:`, a key the vendored component macro " <>
             "silently drops. Use `description:` instead -- it is the key that " <>
             "actually reaches the JSON Schema."
  end
end
