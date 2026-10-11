defmodule CmsHarness.Agents.ACliAgentInTestRunsNoRealCliTest do
  @moduledoc """
  An agent launched on `openai-codex` in the suite answers from a recording.

  Spex whose project connected OpenAI started a real `codex exec` on every
  analysis, from a temp checkout — six sessions a run, about four million
  uncached tokens a day on the fleet's own account. Nothing failed, so nothing
  said so.

  Also how `test/fixtures/cli_recordings/agent_cli.json` is made: run this file
  with `SPEX_CASSETTE_MODE=record` and its two turns are a fresh `exec` and a
  `resume`.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Agents
  alias CmsHarness.Agents.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    CmsHarnessTest.Machine.ensure_supervisor()
    id = "agent-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Agents.launch(%{
        "agent_id" => id,
        "provider" => "openai-codex",
        "working_copy" => root,
        "on_register" => fn _, _ -> :ok end,
        "on_consume" => fn _, _, _ -> :ok end,
        "role" => "coding"
      })

    on_exit(fn -> Agents.halt(id) end)
    %{id: id}
  end

  test "a fresh turn and a resumed one both answer from the recording", %{id: id} do
    sessions_before = codex_sessions()

    assert {:ok, first} =
             Engine.send_message(
               id,
               Ecto.UUID.generate(),
               "Reply with the single word: ready.",
               180_000,
               await: true
             )

    assert {:ok, second} =
             Engine.send_message(
               id,
               Ecto.UUID.generate(),
               "Reply with the single word: again.",
               180_000,
               await: true
             )

    for result <- [first, second] do
      assert result.status == :completed, "the recorded turn did not complete: #{inspect(result)}"
    end

    recording? = System.get_env("SPEX_CASSETTE_MODE") == "record"

    assert recording? or codex_sessions() == sessions_before,
           "a test agent started a real codex session"
  end

  defp codex_sessions do
    Path.wildcard(Path.expand("~/.codex/sessions/**/*.jsonl")) |> MapSet.new()
  end
end
