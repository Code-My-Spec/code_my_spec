defmodule CmsHarness.Agents.InboundTest do
  @moduledoc """
  Story 1123: whether a terminal session takes what we write to its socket,
  read as Claude Code reads `crossSessionInbound` — managed and repository
  settings only tighten, a person's local setting beats their user setting,
  and an unset one holds only for a session that bypasses permission prompts.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Inbound

  @moduletag :tmp_dir

  defp layers(dir, settings) do
    for {layer, value} <- settings do
      path = Path.join(dir, "#{layer}.json")
      File.write!(path, Jason.encode!(%{"crossSessionInbound" => value}))
      {layer, path}
    end
  end

  defp missing(dir), do: [managed: Path.join(dir, "none.json"), user: Path.join(dir, "none.json")]

  test "unset, an ordinary session takes our messages", %{tmp_dir: dir} do
    assert Inbound.verdict(dir, "default", missing(dir)) == :accept
    assert Inbound.verdict(dir, "auto", missing(dir)) == :accept
  end

  test "unset, a session that bypasses prompts holds them, and says how to accept", %{
    tmp_dir: dir
  } do
    assert {:held, why} = Inbound.verdict(dir, "bypassPermissions", missing(dir))
    assert why =~ "bypasses permission prompts"
    assert why =~ "accept"
  end

  test "a person's accept lets a bypassing session take them", %{tmp_dir: dir} do
    assert Inbound.verdict(dir, "bypassPermissions", layers(dir, user: "accept")) == :accept
  end

  test "local beats user", %{tmp_dir: dir} do
    assert {:held, why} =
             Inbound.verdict(dir, "default", layers(dir, local: "hold", user: "accept"))

    assert why =~ "local.json"
  end

  test "managed and repository settings tighten over a person's accept", %{tmp_dir: dir} do
    assert {:refused, why} =
             Inbound.verdict(dir, "default", layers(dir, managed: "refuse", user: "accept"))

    assert why =~ "managed.json"

    assert {:held, _} =
             Inbound.verdict(dir, "default", layers(dir, project: "hold", user: "accept"))
  end

  test "a repository's accept loosens nothing", %{tmp_dir: dir} do
    assert {:held, _} =
             Inbound.verdict(dir, "bypassPermissions", layers(dir, project: "accept"))
  end

  test "an unrecognised value holds", %{tmp_dir: dir} do
    assert {:held, why} = Inbound.verdict(dir, "default", layers(dir, user: "sometimes"))
    assert why =~ "unrecognised"
  end
end
