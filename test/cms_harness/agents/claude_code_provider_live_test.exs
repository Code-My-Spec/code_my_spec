defmodule CmsHarness.Agents.ClaudeCodeProviderLiveTest do
  @moduledoc """
  Proof that `"claude-code"` works as a real provider through the actual
  `CmsHarness.Agents` entry point — not `AlloyClaudeCode.complete/3`
  called directly, which only proves the library, not the wiring.

  Hits the real, installed `claude` CLI — requires a working, authenticated
  `claude` binary on PATH. Excluded from the default `mix test` run via the
  existing `:live` tag; opt in with:

      mix test --only live test/cms_harness/agents/claude_code_provider_live_test.exs

  Every assertion here goes through `CmsHarness.Agents.launch/1` and
  `CmsHarness.Agents.send_message/5`, exactly as the server would drive them —
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

    # Live means the real CLI, so the recording `config/test.exs` pins every
    # other test to is set aside for this one.
    pinned = Application.fetch_env!(:code_my_spec, CmsHarness.Agents.Provider)
    Application.delete_env(:code_my_spec, CmsHarness.Agents.Provider)
    on_exit(fn -> Application.put_env(:code_my_spec, CmsHarness.Agents.Provider, pinned) end)

    %{root: tmp_dir}
  end

  defp execute(id, text),
    do: Agents.send_message(id, Ecto.UUID.generate(), text, 180_000, await: true)

  defp request(root, overrides \\ %{}) do
    Map.merge(
      %{
        "agent_id" => "claude-code-live-#{System.unique_integer([:positive])}",
        "provider" => "claude-code",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      },
      overrides
    )
  end

  test "a plain question gets a real answer from the real claude CLI", %{root: root} do
    assert {:ok, %{agent_id: id}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, text} = execute(id, "Reply with exactly the word PROVIDER-WORKS.")
    assert text =~ "PROVIDER-WORKS"
  end

  test "the agent actually reads a real file through the real tool loop", %{root: root} do
    File.write!(Path.join(root, "pricing.txt"), "the plan charges per seat\n")

    assert {:ok, %{agent_id: id}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, text} =
             execute(
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
    # One engine holds the conversation, and hands each turn's provider state
    # to the next: the second turn resumes the first turn's Claude Code session
    # rather than starting a new one with the whole transcript. A fresh session
    # would also recall the codeword, so the session id is what proves it.
    assert {:ok, %{agent_id: id, pid: engine}} = Agents.launch(request(root))
    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, _} = execute(id, "My favourite fruit is the mangosteen. Reply with just ONE.")
    assert %{session_id: session} = :sys.get_state(engine).provider_state
    assert is_binary(session)

    assert {:ok, text} = execute(id, "What is my favourite fruit?")
    assert text =~ ~r/mangosteen/i

    assert :sys.get_state(engine).provider_state.session_id == session,
           "the second turn started a new Claude Code session instead of resuming the first"
  end

  # The engine streams whenever someone is watching: text arrives as
  # `:text_delta` envelopes, handed to `on_draft` (the conversation page's live
  # draft) rather than reported as steps.
  test "a watched turn streams its reply as text deltas", %{root: root} do
    test_pid = self()

    {:ok, %{agent_id: id}} =
      Agents.launch(%{
        "agent_id" => "claude-code-live-#{System.unique_integer([:positive])}",
        "provider" => "claude-code",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "on_event" => fn _id, envelope -> send(test_pid, {:event, envelope}) end,
        "on_draft" => fn _id, envelope -> send(test_pid, {:draft, envelope}) end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)

    assert {:ok, :started} =
             Agents.send_message(
               id,
               Ecto.UUID.generate(),
               "Write two short sentences about rivers."
             )

    assert_receive {:event, %{event: :turn_ended}}, 170_000
    assert_received {:draft, %{event: :text_delta, payload: delta}} when is_binary(delta)
    assert_received {:event, %{event: :message, text: text}} when is_binary(text)
  end
end
