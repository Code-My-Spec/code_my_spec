defmodule CodeMySpecSpex.Story1046.Criterion1574Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 1574 — Promotion is offered only after the story passes QA.

  Rule (story 1003, Three Amigos, phase 2 of story 1108): `code_on_running_copy`
  depends on `qa_complete` in the graph, so `PromoteWork` cannot become
  actionable before a QA pass exists. Criterion 1179 proves the negative half
  of this on its own (a checkout ahead of main is routed to testing, not a
  promotion); this criterion is the causal pair — the same story, before and
  after the pass, so the offer is shown flipping rather than shown twice in
  isolation.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.PromotionHelpers
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story is offered promotion only once it has passed QA", criterion: 1574 do
    scenario "the same story, before and after its QA pass" do
      given_ "a story ready for QA, with unpromoted commits on its own copy", context do
        context = a_promotable_project(context)
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_up_to_analysis(context)
        PromotionHelpers.materialize_source_fixture_files(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_qa_readiness_transition(context)
        {:ok, context}
      end

      then_ "before QA, the story is offered testing, not a promotion", context do
        text = ask_for_next_work(context)

        assert text =~ "QaStory",
               "a story with no QA attempt yet should be offered testing. Got: #{text}"

        refute text =~ "PromoteWork",
               "promotion should not be offered before the story has passed QA. " <>
                 "Got: #{text}"

        {:ok, context}
      end

      when_ "QA passes", context do
        {:ok, _attempt} = Fixtures.passed_qa_attempt(context.scope, story_id: context.story.id)
        {:ok, context}
      end

      then_ "after QA, the story is offered a promotion, not testing again", context do
        text = ask_for_next_work(context)

        assert text =~ "PromoteWork",
               "once QA passes, the story should be offered promotion — that is the " <>
                 "whole of what 'offered only after it passes' means. Got: #{text}"

        refute text =~ "QaStory",
               "a story that already passed QA should not be offered testing again. " <>
                 "Got: #{text}"

        {:ok, context}
      end
    end
  end

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

    response =
      ToolLibrary.run(
        "get_next_requirement",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    response_text(response)
  end

  # Two checkouts of one repository, which is what a promotion actually meets.
  # See criterion 1170's own copy of this helper for the full rationale.
  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1574-running")
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

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    agent_root = CodeMySpec.TempFile.dir("spex-1574-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

    {out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    _ = out

    running =
      PromotionHelpers.join_main_working_copy(
        context,
        running_root,
        "the checkout the dev app runs in"
      )

    agent =
      PromotionHelpers.join_local_working_copy(
        context,
        agent_root,
        "the coding agent's copy"
      )

    {:ok, _view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
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
