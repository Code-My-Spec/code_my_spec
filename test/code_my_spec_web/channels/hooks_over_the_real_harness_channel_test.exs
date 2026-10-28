defmodule CodeMySpecWeb.HooksOverTheRealHarnessChannel do
  @moduledoc """
  Hooks, driven the whole way the way production drives them.

  POST to the harness web → `ChannelClient` over a real websocket → the cloud's
  `HarnessProjectChannel` → `CodeMySpec.Hooks.*`, with the files a decision
  reads fetched back over the same socket (`fs_request` / `fs_result`) from a
  checkout on disk. See `CodeMySpecSpex.HarnessHooks`.

  The stop exercised here follows writes sent through the real harness channel.
  QA briefs now live in shared project documents, so writing a legacy brief
  file and stopping the session must leave the stored document unchanged.

  Driven from two async test modules below, so the two run at once (ExUnit
  runs one module's tests in sequence, and modules side by side): two projects,
  two checkouts, two listeners and two channels on one node, each test on its
  own database connection. A leak between them — a shared server URL, a shared
  connection, a channel answering for the other copy — fails one of the two.
  """

  import ExUnit.Assertions

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  @incomplete_brief """
  # QA Brief

  ## Tool

  vibium
  """

  @complete_brief """
  # QA Brief

  ## Tool

  vibium

  ## Auth

  Sign in as the seeded owner.

  ## Seeds

  `mix run priv/repo/seeds.exs`

  ## What To Test

  - The home page renders for a signed-in owner.

  ## Result Path

  `.code_my_spec/qa/result.md`
  """

  @doc "Session-start and two stops across legacy file writes on the real channel."
  def drive_a_session(ctx) do
    ctx =
      HarnessHooks.given_a_live_harness(ctx, files: %{"lib/app.ex" => "defmodule App do\nend\n"})

    session_id = "e2e-#{System.unique_integer([:positive])}"
    story = Fixtures.authored_story(ctx.scope, "Owners see their home page")
    brief = ".code_my_spec/qa/#{story.id}/brief.md"

    started = HarnessHooks.post_hook(ctx, "session-start", %{"session_id" => session_id})

    assert is_binary(started["agent_id"]),
           "session-start should register the session as an agent in the cloud; got #{inspect(started)}"

    {:ok, _} =
      CodeMySpec.Qa.Documents.put(ctx.scope, "qa_story_brief", story.number, @complete_brief)

    write_brief(ctx, session_id, brief, @incomplete_brief)
    first = HarnessHooks.post_hook(ctx, "stop", %{"session_id" => session_id})

    refute first["decision"] == "block", "stop refused: #{inspect(first)}"
    assert_stored_brief(ctx.scope, story.number)
    assert brief_problems(ctx, brief) == []

    write_brief(ctx, session_id, brief, @complete_brief)
    second = HarnessHooks.post_hook(ctx, "stop", %{"session_id" => session_id})

    refute second["decision"] == "block", "stop refused: #{inspect(second)}"
    assert_stored_brief(ctx.scope, story.number)
    assert brief_problems(ctx, brief) == []
  end

  defp assert_stored_brief(scope, story_number) do
    assert {:ok, %{content: @complete_brief}} =
             CodeMySpec.Qa.Documents.get(scope, "qa_story_brief", story_number)
  end

  defp brief_problems(ctx, brief) do
    ctx.scope
    |> CodeMySpec.Problems.list_project_problems(source: "qa_validation")
    |> Enum.filter(&(&1.file_path == brief))
  end

  # The agent's `Write`, and the `post-tool-use` Claude Code sends after it —
  # which is how the cloud learns this session changed the file.
  defp write_brief(ctx, session_id, path, content) do
    absolute = HarnessHooks.write_file(ctx, path, content)

    answer =
      HarnessHooks.post_hook(ctx, "post-tool-use", %{
        "session_id" => session_id,
        "tool_name" => "Write",
        "tool_input" => %{"file_path" => absolute, "content" => content}
      })

    refute answer["decision"] == "block", "post-tool-use refused the write: #{inspect(answer)}"
  end
end

defmodule CodeMySpecWeb.HooksOverTheRealHarnessChannelTest do
  use CodeMySpecSpex.Case, async: true

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "session-start opens the session, and stop judges a file it reads over the channel", ctx do
    CodeMySpecWeb.HooksOverTheRealHarnessChannel.drive_a_session(ctx)
  end
end

defmodule CodeMySpecWeb.HooksOverTheRealHarnessChannelBesideTest do
  use CodeMySpecSpex.Case, async: true

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "the same, at the same time, for another project on the same node", ctx do
    CodeMySpecWeb.HooksOverTheRealHarnessChannel.drive_a_session(ctx)
  end
end
