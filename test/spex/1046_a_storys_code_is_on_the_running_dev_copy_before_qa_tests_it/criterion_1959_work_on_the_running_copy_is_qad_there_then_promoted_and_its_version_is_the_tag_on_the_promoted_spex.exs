defmodule CodeMySpecSpex.Story1046.Criterion1959Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1959 (replaces 1174) — Work on the running copy is QA'd there,
  then promoted, and its version is the tag on the promoted commit.

  Since promotion lands the certified commit exactly and tags it (v2.0.355),
  the version a promotion records is that tag — read from git, not a bump
  commit's `mix.exs`.

  Rule (story 1003, Three Amigos, phase 2 of story 1108): the two halves of
  this story joined into one causal chain. `code_on_running_copy` no longer
  precedes `qa_complete` — it depends on it. A QA pass alone does not land
  the work on main; `promote` is the separate, deliberate act that does, and
  only after that act does `code_on_running_copy` read satisfied.

  This is the connective tissue between criterion 1170 (QA runs on the
  copy's own commit) and criteria 1171/1172 (a clean copy promotes what is
  on it): a QA pass earns nothing on its own — `code_on_running_copy` stays
  false until a real promotion actually lands the commit that was tested.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story's own copy is QA'd, then promoted, and its version is the tag on the promoted commit",
    criterion: 1959 do
    scenario "a QA pass alone does not satisfy code_on_running_copy — promotion does" do
      given_ "a story ready for QA, with its work committed on the agent's own copy",
             context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)

        {:ok, context}
      end

      when_ "QA passes on that copy", context do
        {:ok, _attempt} = Fixtures.passed_qa_attempt(context.scope, story_id: context.story.id)
        {:ok, context}
      end

      then_ "code_on_running_copy is still unsatisfied — a pass alone lands nothing",
            context do
        text = code_on_running_copy_status(context)

        refute text =~ "[x] **story_promoted**",
               "a QA pass should not, by itself, satisfy code_on_running_copy — only " <>
                 "an actual promotion lands the work on main. Got: #{text}"

        {:ok, context}
      end

      when_ "the story is promoted", context do
        context = analyzers_are_current(context)
        response = promote(context, context.story.number)
        answer_restart_app_ok(context.running_socket)
        {:ok, Map.put(context, :promote_response, response)}
      end

      then_ "the work is on the running copy and code_on_running_copy now reads satisfied",
            context do
        assert exists?(context.running_root, "lib/broken_oaths/diplomacy/war.ex"),
               "the story's commit was not merged onto the running copy by a promotion " <>
                 "that reported: #{response_text(context.promote_response)}"

        text = code_on_running_copy_status(context)

        assert text =~ "[x] **story_promoted**",
               "once promoted, code_on_running_copy should read satisfied — the QA " <>
                 "pass and the promotion together are what this requirement means. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      then_ "its version is the tag on the commit that landed", context do
        {tag, 0} =
          git(context, context.running_root, ["describe", "--tags", "--exact-match", "HEAD"])

        tag = String.trim(tag)
        assert tag =~ ~r/^v\d+\.\d+\.\d+$/, "the promoted commit carries no version tag: #{tag}"

        assert response_text(context.promote_response) =~ String.trim_leading(tag, "v"),
               "the promotion did not report the version it tagged (#{tag}): " <>
                 response_text(context.promote_response)

        {:ok, context}
      end
    end
  end

  defp code_on_running_copy_status(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ListRequirements.execute(
        %{
          entity_type: "story",
          entity_id: to_string(context.story.number),
          requirement_name: "story_promoted"
        },
        frame
      )

    response_text(response)
  end

  # Both copies' analyzers are current — a real precondition of the promote
  # gate, not test scaffolding. See criterion 1172's own note.
  defp analyzers_are_current(context) do
    Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex), at_head: true)

    Fixtures.fresh_analysis_runs(
      %{context.scope | active_working_copy_id: context.running.working_copy_id},
      ~w(compiler credo exunit spex),
      at_head: true
    )

    context
  end

  # Through `promote_sync` rather than `promote` — see criterion 1172's own
  # note on why a spec needs the door that answers rather than the one that
  # messages back.
  defp promote(context, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
  end

  # Standing in for the harness on the other end of `restart_app`, the way
  # criterion 1183's own `answer_restart_app/2` does. `Runner.restart/3`
  # dispatches the restart through `AppTransport.restart_app/2` and never
  # awaits it (54aa534c, phase two) — leaving it unanswered would not fail
  # this test, it would leave a detached task blocked on this channel for
  # the full 10-minute `@restart_timeout`, risking an error log landing in
  # the middle of an unrelated later test.
  defp answer_restart_app_ok(socket) do
    assert_push "restart_app", %{"ref" => ref}, 5_000

    reply_ref =
      Phoenix.ChannelTest.push(socket, "restart_app_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4100",
        "app_commit" => "cafef00d"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("restart_app_result was never acknowledged")
    end
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  # See criterion 1170's own copy of this helper for the full rationale.
  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1174-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))

    write(running_root, "justfile", """
    restart:
        @elixirc -o {{justfile_directory()}}/_spex_build \\
            {{justfile_directory()}}/lib/broken_oaths/diplomacy/*.ex
        @date > {{justfile_directory()}}/.restarted
    """)

    # `Promotion.Steps.bump_version/2` reads `version: "X.Y.Z"` out of
    # `HEAD:mix.exs` on the running checkout; without one the merge still
    # lands but mints no version, and `stamp_promoted_stories/2` stamps
    # nothing on `nil` — the story's `promoted_version` would stay nil
    # forever and `code_on_running_copy` could never be satisfied by this
    # scenario. Never `elixirc`'d, so it does not need to be valid Elixir
    # beyond that one string.
    write(running_root, "mix.exs", ~s(version: "0.1.0"\n))

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("spex-1174-agent")
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

  defp exists?(root, path), do: Environments.file_exists?(disk(root), path)
end
