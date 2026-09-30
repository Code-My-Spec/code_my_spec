defmodule CodeMySpecSpex.Story1046.Criterion1376Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1376 — A failed deployment is not silence.

  Rule (`Promotion.tell_the_agent/4`, `lib/code_my_spec/promotion.ex`, old id
  "criterion 3437", commit 0060d67d): `promote` answers as soon as the merge
  lands — "merged, QA can start" — before the detached restart resolves.
  `Promotion.Runner.restart/3` dispatches the restart through
  `WorkingCopies.AppTransport.restart_app/2`, the same channel verb every
  working copy's own app answers to (story 1108). If that restart genuinely
  fails, the earlier answer is wrong and nothing retracts it on its own; the
  only in-band record would otherwise be a `Logger.error` in web.log that
  nobody not already tailing it reads. The fix delivers a correction to the
  promoting agent directly: the merge is still on the running copy (nothing
  rolled back), the application is NOT serving it, and what broke the restart.

  See `test/code_my_spec/promotion/a_failed_deployment_corrects_the_agent_test.exs`
  for the unit-level coverage — written before `Runner.restart/3` moved onto
  `AppTransport`, so it fakes the failure with a `justfile` recipe that exits
  non-zero rather than a channel reply. This spec answers the `restart_app`
  push directly instead, the way criterion 1183's own `answer_restart_app/2`
  does for its (successful) case — `decode_app_result/1` turns an `app_status`
  other than `"serving"` into `{:error, ...}`, which is neither a lost
  acknowledgement nor ambiguous (`Promotion.restart_acknowledgement_lost?/1`
  reserves that for a dropped channel or an RPC timeout), so it classifies as
  a genuine `{:failed, reason}`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.PromotionHelpers, only: [a_promotable_story: 1]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok = Fixtures.install_recording_agent_transport()

    # The correction is sent from the detached restart task, which checks
    # out its own connection.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A restart that fails after a promotion corrects the agent it already told",
       criterion: 1376 do
    scenario "the copy's own app answers down after the restart" do
      given_ "a promotable project, with an agent to correct if the restart fails",
             context do
        context = a_promotable_project(context)

        {:ok, agent} =
          AgentsRepository.create_agent(context.scope, %{
            provider: "anthropic",
            engine: :alloy,
            role: "coding",
            working_copy: context.agent_root,
            working_copy_id: context.agent.working_copy_id
          })

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        story = a_promotable_story(context)
        analyzers_are_current(context)

        {:ok, context |> Map.put(:agent, agent) |> Map.put(:story, story)}
      end

      when_ "the agent promotes, and the restart comes back down rather than serving",
            context do
        response = promote(context, context.story.number)
        answer_restart_app_down(context.running_socket)

        # Waited for here, before inspecting the error log below — the log
        # line and the correction are two steps of the same detached
        # pipeline (`classify_restart |> log_restart_outcome |> tell_the_agent`),
        # and the correction is the later of the two. Waiting for it first
        # means the log has definitely already landed.
        agent_id = context.agent.id

        assert_receive {:agent_dispatch, ^agent_id, _ref, correction}, 5_000,
                        "the restart failed outright and no correction reached the agent — " <>
                          "it is still holding the earlier 'merged, QA can start' answer, " <>
                          "which is now false."

        # A restart that genuinely fails logs at `:error` — this scenario
        # provokes that on purpose, not by surprise, so it has to inspect and
        # clear it itself or this project's spex-wide "no error-level log
        # during a spex" rule (`SexySpex.ErrorCapture`) fails this run for
        # producing exactly the condition it exists to prove is not silent.
        # See criterion 4663's own note on the same rule.
        errors = SexySpex.ErrorCapture.get_errors()
        assert errors != [], "expected the restart failure to log at :error"

        for error <- errors do
          assert error.message =~ "restart FAILED"
        end

        SexySpex.ErrorCapture.clear()

        {:ok, context |> Map.put(:promote_response, response) |> Map.put(:correction, correction)}
      end

      then_ "the merge is reported to have landed", context do
        text = response_text(context.promote_response)

        assert text =~ "Merged into",
               "the premise failed: the merge itself should have landed cleanly, " <>
                 "leaving only the restart to fail. Got: #{text}"

        {:ok, context}
      end

      then_ "the correction says the merge landed, the app is not serving it, and why",
            context do
        correction = context.correction

        assert correction =~ "Correction on the promotion",
               "the message should read as a correction to the answer already given. " <>
                 "Got: #{correction}"

        assert correction =~ "Nothing was rolled back",
               "the correction has to say the merge is still on the running copy — " <>
                 "otherwise 'the deployment failed' reads as 'the merge came back out', " <>
                 "and an agent that believes that promotes the same work twice. " <>
                 "Got: #{correction}"

        {:ok, context}
      end
    end
  end

  defp analyzers_are_current(context) do
    Fixtures.fresh_analysis_runs(context.scope)

    Fixtures.fresh_analysis_runs(%{
      context.scope
      | active_working_copy_id: context.running.working_copy_id
    })

    context
  end

  defp promote(context, story_number) do
    frame = %Anubis.Server.Frame{
      assigns: %{current_scope: context.scope, agent_id: context.agent.id}
    }

    {:reply, response, _frame} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
  end

  # Standing in for the harness on the other end of `restart_app`, the way
  # criterion 1183's own `answer_restart_app/2` does — except this app comes
  # back down instead of serving, which is what makes the restart a genuine
  # failure rather than a confirmed one.
  defp answer_restart_app_down(socket) do
    assert_push "restart_app", %{"ref" => ref}, 5_000

    reply_ref =
      Phoenix.ChannelTest.push(socket, "restart_app_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "down",
        "app_url" => nil,
        "app_commit" => nil
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("restart_app_result was never acknowledged")
    end
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  # See criterion 1170's own copy of this helper for the full rationale. The
  # running copy keeps its socket — this spec answers `restart_app` on it.
  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1376-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))
    write(running_root, "mix.exs", ~s(version: "0.1.0"\n))

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("spex-1376-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

    {out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    _ = out

    {running, running_socket} =
      join_working_copy_socket(context, running_root, "the checkout the dev app runs in")

    agent = join_working_copy(context, agent_root, "the coding agent's copy")

    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
    |> Map.put(:running_socket, running_socket)
    |> Map.put(:agent, agent)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  defp git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)
end
