defmodule CmsHarness.Agents.ClaudeCodeProviderLiveTest do
  @moduledoc """
  Proof that `"claude-code"` works as a real provider through the actual
  `CmsHarness.Agents` entry point — not `Alloy.Provider.ClaudeCode.complete/3`
  called directly, which only proves the library, not the wiring.

  Hits the real, installed `claude` CLI — requires a working, authenticated
  `claude` binary on PATH. Excluded from the default `mix test` run via the
  existing `:live` tag; opt in with:

      mix test --only live test/cms_harness/agents/claude_code_provider_live_test.exs

  Every assertion here goes through `CmsHarness.Agents.launch/1` and
  `CmsHarness.Agents.message/3`, exactly as the server would drive them —
  `Provider.options/3`'s `"claude-code"` clause, `Engine.alloy_options/2`
  passing `working_copy` through as a stable `:workdir`, and the tool loop
  (`Alloy.Tool.Core.Read` among the real tools an agent carries) are all
  exercised for real.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents

  @moduletag :tmp_dir
  @moduletag :live
  @moduletag timeout: 60_000

  setup %{tmp_dir: tmp_dir} do
    CmsHarnessTest.Machine.ensure_supervisor()
    %{root: tmp_dir}
  end

  defp request(root, overrides \\ %{}) do
    Map.merge(
      %{
        "agent_id" => "claude-code-live-#{System.unique_integer([:positive])}",
        "provider" => "claude-code",
        "working_copy" => root,
        "role" => "coding"
      },
      overrides
    )
  end

  test "a plain question gets a real answer from the real claude CLI", %{root: root} do
    assert {:ok, %{agent_id: id}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, text} = Agents.message(id, "Reply with exactly the word PROVIDER-WORKS.")
    assert text =~ "PROVIDER-WORKS"
  end

  test "the agent actually reads a real file through the real tool loop", %{root: root} do
    File.write!(Path.join(root, "pricing.txt"), "the plan charges per seat\n")

    assert {:ok, %{agent_id: id}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, text} =
             Agents.message(
               id,
               "Read pricing.txt in the working directory and tell me exactly what it says."
             )

    assert text =~ "per seat",
           "the agent answered #{inspect(text)} without apparently reading the file - " <>
             "claude-code's own tool-suppression means it can only get this right by " <>
             "asking Alloy's tool loop to read it, not by doing so itself"
  end

  test "a second turn on the same agent carries the first turn's context forward",
       %{root: root} do
    # This proves the wiring holds a conversation together across turns:
    # one Engine, one Alloy.Agent.Server, and (per Alloy.Provider.ClaudeCode's
    # own moduledoc and live test suite) --resume underneath so the second
    # turn is a real prompt-cache hit rather than the full transcript being
    # re-sent - that specific cost claim already has a live assertion with
    # direct visibility into response_metadata.cache_read_input_tokens at
    # the Alloy layer, where it belongs. This test only needs to prove the
    # content actually carries across two real `Agents.message/2` calls
    # through this harness's own entry point.
    assert {:ok, %{agent_id: id}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, _} = Agents.message(id, "Remember the codeword MANGO-31. Reply with just ONE.")
    assert {:ok, text} = Agents.message(id, "What was the codeword?")
    assert text =~ "MANGO-31"
  end
end
