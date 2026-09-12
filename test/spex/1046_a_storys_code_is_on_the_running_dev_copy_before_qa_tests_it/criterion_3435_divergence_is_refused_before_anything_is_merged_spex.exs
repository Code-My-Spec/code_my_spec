defmodule CodeMySpecSpex.Story1046.Criterion3435Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3435 — Divergence is refused before anything is merged.

  Rule: Whether a merge can succeed is decided before it is attempted, and
  refused plainly when it cannot.

  ## Why this criterion exists

  John, 2026-09-12, after a promotion held the project's lock for 45 minutes and
  had to be cleared by restarting the shared dev server: "the merge needs to
  happen immediately — we can know if the merge will succeed, and we need to
  immediately merge and then start the deployment async after that. This friction
  is unacceptable."

  "We can know if the merge will succeed" is the load-bearing half. It is what
  makes an immediate, unconditional merge safe rather than reckless: the
  precondition is checked first, so by the time the merge runs there is nothing
  left for it to discover. Refusing earlier is what buys the merge being
  unconditional — the opposite of a corner cut.

  ## What is asserted, and what would pass falsely

  Two things, and the second is the one a partial implementation satisfies.

  A refusal is easy. A refusal *that left the target alone* is the claim: an
  implementation that attempts the merge, hits a conflict, aborts, and then
  reports a refusal also produces a refusal — while having touched the shared
  checkout every other project on the machine is reading. So this asserts the
  running copy's HEAD is exactly where it was, and that no merge is in progress.

  `MERGE_HEAD` is checked rather than inferred from the log, because an aborted
  merge and a merge never attempted have the same history and differ only in
  what was left behind.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spec_tags = []
  _ = spec_tags

  spex "A branch that does not contain main is refused before the merge" do
    scenario "somebody else's commit landed on main while this agent worked" do
      given_ "a story branch with work on it", context do
        context = a_promotable_project(context)

        write(context.agent_root, "lib/broken_oaths/diplomacy/war.ex", war(":from_the_copy"))
        {_, 0} = git(context, context.agent_root, ["commit", "-q", "-am", "the story's work"])

        {:ok, context}
      end

      given_ "and a commit on main the branch does not have", context do
        write(context.running_root, "lib/broken_oaths/diplomacy/treaty.ex", treaty())
        {_, 0} = git(context, context.running_root, ["add", "-A"])

        {_, 0} =
          git(context, context.running_root, ["commit", "-q", "-m", "somebody else's work"])

        # The premise, stated rather than assumed: this is divergence, not a
        # branch that is merely behind. Both sides have something the other
        # does not, which is the case a fast-forward cannot serve.
        {out, 0} =
          git(context, context.agent_root, [
            "rev-list",
            "--left-right",
            "--count",
            "main...story/war"
          ])

        [behind, ahead] =
          out |> String.trim() |> String.split(~r/\s+/) |> Enum.map(&String.to_integer/1)

        assert behind > 0 and ahead > 0,
               "the premise failed: this is not divergence (#{behind} behind, #{ahead} ahead)"

        {:ok, Map.put(context, :head_before, head_of(context, context.running_root))}
      end

      given_ "both copies' analyzers are current", context do
        {:ok, analyzers_are_current(context)}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "it is refused, and told to merge main into its own branch", context do
        text = response_text(context.response)

        assert context.response.isError,
               """
               A diverged branch was promoted rather than refused. The merge is
               unconditional precisely because this check ran first; without it,
               the merge is the thing that discovers the problem — on the shared
               checkout, after it has already started. Got: #{text}
               """

        assert text =~ "merge" and text =~ "main",
               """
               The refusal does not name the remedy. Divergence is ordinary on a
               shared checkout — somebody else promoting while you worked — so
               this string is read constantly and has to say what to do rather
               than only what is wrong. Got: #{text}
               """

        {:ok, context}
      end

      and_ "the running copy was not touched", context do
        assert head_of(context, context.running_root) == context.head_before,
               """
               The running copy's HEAD moved on a promotion that was refused.
               Every other project on this machine reads that checkout.
               """

        refute exists?(context.running_root, ".git/MERGE_HEAD"),
               """
               A merge was attempted and left in progress on the shared checkout.
               A refusal that aborts a merge it should never have started looks
               identical to this one from the caller's side, and differs entirely
               for whoever works in that checkout next — which is why this is
               asserted on MERGE_HEAD rather than on the history, where an
               aborted merge and a merge never attempted are indistinguishable.
               """

        refute exists?(context.running_root, ".restarted"),
               "a refused promotion restarted the application"

        {:ok, context}
      end
    end
  end

  defp head_of(context, root) do
    {out, 0} = git(context, root, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  defp analyzers_are_current(context) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope)

    CodeMySpecSpex.Fixtures.fresh_analysis_runs(%{
      context.scope
      | active_working_copy_id: context.running.working_copy_id
    })

    context
  end

  defp a_promotable_project(context) do
    running_root = CodeMySpec.TempFile.dir("spex-1046-running")
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

    agent_root = CodeMySpec.TempFile.dir("spex-1046-agent")
    {_, 0} = Environments.cmd(context.environment, "rm", ["-rf", agent_root])

    {_out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    running = join_working_copy(context, running_root, "the checkout the dev app runs in")
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
    |> Map.put(:agent, agent)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  defp promote(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{}, frame)
    response
  end

  defp git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  defp war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  defp treaty do
    "defmodule BrokenOaths.Diplomacy.Treaty do\n  def sign, do: :signed\nend\n"
  end

  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)

  defp exists?(root, path), do: Environments.file_exists?(disk(root), path)
end
