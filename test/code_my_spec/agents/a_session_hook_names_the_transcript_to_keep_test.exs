defmodule CodeMySpec.Agents.ASessionHookNamesTheTranscriptToKeepTest do
  @moduledoc """
  Issue c82e1d2d: the path a session's SessionStart hook names is kept on its
  agent, so a re-attach after a harness restart reads it back rather than
  working it out.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents
  alias CodeMySpec.Hooks.SessionStart

  setup do
    scope = full_scope_fixture()
    root = "/workspace/transcript-#{System.unique_integer([:positive])}"

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "the main checkout",
        root: root,
        device: device_fixture(scope)
      )

    {:ok, copy} = CodeMySpec.WorkingCopies.report_root(copy, root)
    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  test "the hook's transcript_path is kept, for either engine", %{scope: scope} do
    claude = %{"session_id" => "cc-1", "transcript_path" => "/tmp/cc-1.jsonl"}
    codex = %{"session_id" => "cx-1", "transcript_path" => "/tmp/cx-1.jsonl", "engine" => "codex"}

    for params <- [claude, codex] do
      assert {200, %{agent_id: id}} = SessionStart.handle(scope, params)
      assert {:ok, %{transcript_path: path}} = Agents.fetch_agent(scope, id)
      assert path == params["transcript_path"]
    end
  end

  test "a resumed session names its transcript again and the new path is kept", %{scope: scope} do
    first = %{"session_id" => "cc-2", "transcript_path" => "/tmp/one.jsonl"}
    assert {200, %{agent_id: id}} = SessionStart.handle(scope, first)

    assert {200, %{agent_id: ^id}} =
             SessionStart.handle(scope, %{first | "transcript_path" => "/tmp/two.jsonl"})

    assert {:ok, %{transcript_path: "/tmp/two.jsonl"}} = Agents.fetch_agent(scope, id)
  end
end
