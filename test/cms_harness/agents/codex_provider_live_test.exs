defmodule CmsHarness.Agents.CodexProviderLiveTest do
  @moduledoc """
  `"openai-codex"` through the `CmsHarness.Agents` entry point, against the
  real, logged-in `codex` CLI and this machine's `CODEX_HOME`. Excluded by the
  `:live` tag; opt in with:

      mix test --only live test/cms_harness/agents/codex_provider_live_test.exs
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents

  @moduletag :tmp_dir
  @moduletag :live
  @moduletag timeout: 300_000

  setup %{tmp_dir: tmp_dir} do
    CmsHarnessTest.Machine.ensure_supervisor()
    pinned = Application.fetch_env!(:code_my_spec, CmsHarness.Agents.Provider)
    Application.delete_env(:code_my_spec, CmsHarness.Agents.Provider)
    on_exit(fn -> Application.put_env(:code_my_spec, CmsHarness.Agents.Provider, pinned) end)
    %{root: tmp_dir}
  end

  defp execute(id, text),
    do: Agents.send_message(id, Ecto.UUID.generate(), text, 280_000, await: true)

  defp launch(root) do
    {:ok, %{agent_id: id, pid: engine}} =
      Agents.launch(%{
        "agent_id" => "codex-live-#{System.unique_integer([:positive])}",
        "provider" => "openai-codex",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    {id, engine}
  end

  test "a second turn resumes the first turn's Codex thread", %{root: root} do
    {id, engine} = launch(root)

    assert {:ok, _} = execute(id, "My favourite tree is the baobab. Reply with just ONE.")
    assert %{"codex_session" => %{"id" => thread}} = :sys.get_state(engine).provider_state

    assert {:ok, text} = execute(id, "What is my favourite tree?")
    assert text =~ ~r/baobab/i

    assert get_in(:sys.get_state(engine).provider_state, ["codex_session", "id"]) == thread,
           "the second turn started a new Codex thread instead of resuming the first"
  end

  # Codex runs read-only, and its own shell is off: an edit has to come back to
  # the outer loop as a write call. A model that reads "read-only" as a reason
  # not to edit leaves the file unwritten.
  test "an edit is made through the outer loop's write tool", %{root: root} do
    {id, _engine} = launch(root)

    assert {:ok, _} =
             execute(
               id,
               "Create a file named hello.txt in the working directory containing exactly " <>
                 "the text: hi from codex"
             )

    path = Path.join(root, "hello.txt")
    assert File.exists?(path), "Codex did not write hello.txt"
    assert File.read!(path) =~ "hi from codex"
  end

  # The engine streams whenever someone is watching: text arrives as
  # `:text_delta` envelopes, handed to `on_draft` (the conversation page's live
  # draft) rather than reported as steps.
  test "a watched turn streams its reply as text deltas", %{root: root} do
    test_pid = self()

    {:ok, %{agent_id: id}} =
      Agents.launch(%{
        "agent_id" => "openai-codex-live-#{System.unique_integer([:positive])}",
        "provider" => "openai-codex",
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

    assert_receive {:event, %{event: :turn_ended}}, 280_000
    assert_received {:draft, %{event: :text_delta, payload: delta}} when is_binary(delta)
    assert_received {:event, %{event: :message, text: text}} when is_binary(text)
  end
end
