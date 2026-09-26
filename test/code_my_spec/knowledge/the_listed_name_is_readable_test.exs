defmodule CodeMySpec.Knowledge.TheListedNameIsReadableTest do
  @moduledoc """
  `f293dce0`: `list_knowledge` printed `main_agent` and `read_knowledge` answered
  "Knowledge entry not found: process/main_agent". The listing strips `.md`, the
  reader wanted it, and an agent that followed the index got nothing.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Knowledge
  alias CodeMySpec.Users.Scope

  @scope %Scope{}

  test "a name as the listing prints it reads" do
    assert {:ok, content} = Knowledge.resolve(@scope, :knowledge, ["process", "main_agent"])
    assert is_binary(content) and content != ""
  end

  test "the name with its extension still reads" do
    assert {:ok, with_ext} = Knowledge.resolve(@scope, :knowledge, ["process", "main_agent.md"])
    assert {:ok, without_ext} = Knowledge.resolve(@scope, :knowledge, ["process", "main_agent"])
    assert with_ext == without_ext
  end

  test "every name the listing prints for a directory reads" do
    {:ok, listing} = Knowledge.resolve(@scope, :knowledge, ["process"])

    names =
      Regex.scan(~r/^- (\S+)$/m, listing)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.reject(&String.ends_with?(&1, "/"))

    assert names != [], "the process listing printed no files, so this proves nothing"

    for name <- names do
      assert {:ok, _} = Knowledge.resolve(@scope, :knowledge, ["process", name]),
             "listing printed #{inspect(name)} but reading it failed"
    end
  end

  test "an absent name is still absent" do
    assert {:error, :not_found} =
             Knowledge.resolve(@scope, :knowledge, ["process", "no_such_entry"])
  end
end
