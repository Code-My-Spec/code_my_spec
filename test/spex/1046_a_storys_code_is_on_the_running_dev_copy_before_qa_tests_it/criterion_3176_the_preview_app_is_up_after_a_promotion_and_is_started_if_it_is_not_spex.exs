defmodule CodeMySpecSpex.Story1046.Criterion3176Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3176 — The preview app is up after a promotion, and is started if it
  is not.

  Rule: The running application must be serving the code that was promoted.

  The half `code_on_running_copy` did not cover, and the gap showed within a day
  of shipping it. The gate proved the code was on the running copy and said
  nothing about whether anything was serving it — so Broken Oaths' preview went
  down, the gate stayed satisfied, and a QA agent stood in front of a connection
  refused with the graph reporting the story ready to test.

  What it did next is the reason this is a rule rather than a nicety: it asked
  for permission to restart the app itself. Restarting would have started it on
  code that did not contain the work it was there to verify, and QA would then
  have tested a healthy-looking application missing the feature — the nine false
  failures of 2026-09-09 with the sign flipped.

  So the state QA depends on is both halves at once: the code is here, and the
  thing QA opens is answering. A checkout that is behind *and* down gets one
  instruction, because `promote` fixes both — it brings the work across and
  restarts on the way.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A story is not ready for QA while its application is down" do
    scenario "the code is on the running copy and nothing is answering" do
      given_ "a story ready for QA, on the checkout the application runs from", context do
        # The chain first. Joining or designating a checkout before it leaves
        # the story short of `bdd_specs_passing`, and the graph then answers
        # with an earlier task instead of the node this criterion is about.
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)
        {:ok, this_copy_is_the_running_one(context)}
      end

      given_ "whose application is answering", context do
        report_preview(context, "serving")

        text = ask_for_next_work(context)

        assert text =~ "QaStory",
               "the premise failed: QA was not offered the story even with the " <>
                 "application up, so the assertion below would pass for the " <>
                 "wrong reason. Got: #{text}"

        {:ok, context}
      end

      when_ "the application stops answering", context do
        {:ok, report_preview(context, "down")}
      end

      then_ "QA is no longer offered the story", context do
        text = ask_for_next_work(context)

        refute text =~ "QaStory",
               "QA was sent to test a story whose application is not answering. " <>
                 "It cannot test a connection refused, and what it does instead " <>
                 "is file the story as broken. Got: #{text}"

        {:ok, context}
      end

      then_ "and is told the application is down, not that the story is unfinished",
            context do
        text = ask_for_next_work(context)

        assert text =~ "PromoteWork",
               "the story was not routed to the one action that starts it. Got: #{text}"

        {:ok, context}
      end
    end
  end

  spex "An application that answers with an error is QA's to find" do
    scenario "the application is up and returning 500s" do
      given_ "a story ready for QA, on the checkout the application runs from", context do
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)
        {:ok, this_copy_is_the_running_one(context)}
      end

      when_ "its application answers with an error", context do
        {:ok, report_preview(context, "erroring")}
      end

      then_ "QA is still offered the story", context do
        text = ask_for_next_work(context)

        assert text =~ "QaStory",
               "an application returning 500s came up and is failing, which is " <>
                 "exactly what QA exists to find. Holding it back turns a defect " <>
                 "into a gate nobody is looking at. Got: #{text}"

        {:ok, context}
      end
    end
  end

  spex "A down application is started by the same act that would promote to it" do
    scenario "the agent is working on the running copy and nothing is serving it" do
      given_ "an agent working on the checkout the application runs from", context do
        {:ok, a_running_copy(context)}
      end

      # Recorded, not asserted on here. That the gate refuses a `down` running
      # copy is the first scenario's subject, asked of the product surface with
      # a story in place to be refused about. This scenario is about the other
      # half — that promoting is what starts it again — and a second checkout
      # joining changes which requirement the graph answers with, so asking it
      # here would be asserting about the arrangement rather than the rule.
      given_ "whose application is not answering", context do
        {:ok, report_preview(context, "down")}
      end

      when_ "the agent promotes", context do
        {:ok, Map.put(context, :response, promote(context))}
      end

      then_ "the application is started", context do
        assert exists?(context.running_root, ".restarted"),
               "the gate named `promote` as the way to bring a dead application " <>
                 "back, and promoting did not start it. Got: " <>
                 response_text(context.response)

        {:ok, context}
      end

      # The livelock guard: a restart that does not say it happened leaves the
      # gate reading the `down` it refused on a moment earlier, so the agent is
      # sent to promote again, and again, with the restart succeeding every
      # time. `Promotion.restart/2` records `serving` for exactly this reason.
      #
      # Asserted through the report the agent is handed rather than by reading
      # the column, because the report is what an agent acts on — and a
      # promotion that restarted the application while telling the agent
      # something else is the same failure wearing a different coat.
      then_ "and says so, so the gate stops refusing", context do
        text = response_text(context.response)

        assert text =~ "Restarted" or text =~ "serving",
               "the promotion restarted the application and did not report it as " <>
                 "running, so nothing tells the gate the application came back. " <>
                 "Got: #{text}"

        {:ok, context}
      end
    end
  end

  # Reported the way the harness reports it: measured on the machine, delivered
  # over the channel, recorded on the copy. A spec has no harness, so it records
  # through the same surface the channel handler calls.
  defp report_preview(context, status) do
    CodeMySpecSpex.Fixtures.record_preview_status(
      context.scope.active_working_copy_id,
      status
    )

    context
  end

  # One checkout, which is the arrangement this scenario is about: the agent is
  # working *on* the running copy, so there is no branch and nothing to merge.
  # The other specs in this story build two, because a promotion between copies
  # is what they are about.
  defp a_running_copy(context) do
    running_root = CodeMySpec.TempFile.dir("spex-3176-running")
    {_, 0} = Environments.cmd(context.environment, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    # The project's own restart recipe, which is the seam a promotion uses
    # instead of knowing how to bring a Phoenix app up.
    write(running_root, "justfile", """
    restart:
        @date > {{justfile_directory()}}/.restarted
    """)

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])

    running = join_working_copy(context, running_root, "the checkout the dev app runs in")

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:running, running)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: running.working_copy_id})
  end

  # Through `promote_sync` rather than `promote`: both doors run the same
  # `Promotion.promote/1` and differ only in delivery, and the agent's door
  # returns before there is an outcome to assert on.
  defp promote(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{}, frame)
    response
  end

  # An explicit `:cd` wins over the environment's own cwd, which is what lets
  # one environment drive a checkout on the OS temp filesystem.
  defp git(context, dir, args),
    do: Environments.cmd(context.environment, "git", args, cd: dir, stderr_to_stdout: true)

  # A local environment over the OS temp filesystem, which is where git looks.
  # The suite's own environment fakes the domain filesystem, so a file written
  # through it is invisible to `git`.
  defp disk(root), do: Environment.new(:local, root)

  defp write(root, path, content), do: :ok = Environments.write_file(disk(root), path, content)

  defp exists?(root, path), do: Environments.file_exists?(disk(root), path)

  defp ask_for_next_work(context) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
    response_text(response)
  end

  # Designate this checkout as the one the application runs from, through the
  # page that owns the choice. `main` is "designated, never inferred", so there
  # is no state to set behind the product's back.
  defp this_copy_is_the_running_one(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    view
    |> element(
      "[data-test='designate-main-copy'][phx-value-id='#{context.scope.active_working_copy_id}']"
    )
    |> render_click()

    context
  end
end
