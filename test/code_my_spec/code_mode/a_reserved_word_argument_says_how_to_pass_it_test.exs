defmodule CodeMySpec.CodeMode.AReservedWordArgumentSaysHowToPassItTest do
  @moduledoc """
  Issue 2a269214: `read_agent_conversation` takes `until`, a Lua keyword, so the
  natural call `{ since = "…", until = "…" }` fails to compile. The compile error
  now names the line; the tool's page also says up front how to pass such an
  argument.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.CodeMode
  alias CodeMySpec.CodeMode.Catalog

  defp catalog(properties) do
    Catalog.from(
      [
        %{
          name: "read_window",
          description: "Reads a window.",
          input_schema: %{"type" => "object", "properties" => properties},
          invoke: fn _args -> {:ok, "ok"} end
        }
      ],
      fn tool -> Map.fetch!(tool, :invoke) end
    )
  end

  test "an argument that is a Lua keyword is called out with the string-key form" do
    docs =
      CodeMode.docs(
        catalog(%{
          "since" => %{"type" => "string", "description" => "from"},
          "until" => %{"type" => "string", "description" => "to"}
        }),
        name: "read_window"
      )

    assert docs =~ "Lua reserved word: `until`"
    assert docs =~ ~S{args["until"] = "…"}
    assert docs =~ "read_window(args)"
  end

  test "a tool with no keyword argument gets no such note" do
    docs = CodeMode.docs(catalog(%{"since" => %{"type" => "string"}}), name: "read_window")

    refute docs =~ "reserved word"
  end

  test "the string-key form it recommends actually runs" do
    script = ~S"""
    local args = { since = "a" }
    args["until"] = "b"
    return read_window(args)
    """

    result = CodeMode.eval(catalog(%{"until" => %{"type" => "string"}}), script)

    refute CodeMode.Result.failed?(result)
  end
end
