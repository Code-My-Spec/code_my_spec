defmodule CodeMySpecWeb.HooksOverTheRealHarnessChannel do
  @moduledoc """
  Hooks, driven the whole way the way production drives them.

  POST to the harness web → `ChannelClient` over a real websocket → the cloud's
  `HarnessProjectChannel` → `CodeMySpec.Hooks.*`, with the files a decision
  reads fetched back over the same socket (`fs_request` / `fs_result`) from a
  checkout on disk. See `CodeMySpecSpex.HarnessHooks`.

  The stop exercised here validates a QA brief the session wrote. The cloud has
  no disk: it knows the brief changed from the harness's manifest and the
  session's `post-tool-use`, and it can only judge the brief's content by asking
  the harness to read it. So the same stop runs twice — first recording a
  problem naming the sections the written brief lacks, then clearing it once the
  brief is complete — and the record has to follow what is on disk. A cut
  `fs_request` path reads as "could not read, nothing to report" and records
  nothing the first time. Neither stop blocks: problems gate at promotion.

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

  @doc "session-start, then two stops that judge a file read over the channel."
  def drive_a_session(ctx) do
    ctx =
      HarnessHooks.given_a_live_harness(ctx, files: %{"lib/app.ex" => "defmodule App do\nend\n"})

    session_id = "e2e-#{System.unique_integer([:positive])}"
    story = Fixtures.authored_story(ctx.scope, "Owners see their home page")
    brief = ".code_my_spec/qa/#{story.id}/brief.md"

    started = HarnessHooks.post_hook(ctx, "session-start", %{"session_id" => session_id})

    assert is_binary(started["agent_id"]),
           "session-start should register the session as an agent in the cloud; got #{inspect(started)}"

    write_brief(ctx, session_id, brief, @incomplete_brief)
    first = HarnessHooks.post_hook(ctx, "stop", %{"session_id" => session_id})

    refute first["decision"] == "block", "problems never block a stop: #{inspect(first)}"

    assert [problem] = brief_problems(ctx, brief),
           "the incomplete brief, read over the channel, should be recorded as a problem"

    assert problem.message =~ "Missing required sections: auth, seeds, what to test, result path"

    write_brief(ctx, session_id, brief, @complete_brief)
    second = HarnessHooks.post_hook(ctx, "stop", %{"session_id" => session_id})

    refute second["decision"] == "block", "expected the stop through: #{inspect(second)}"

    assert brief_problems(ctx, brief) == [],
           "the brief on disk is complete, so a problem still standing means it was never re-read"
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
