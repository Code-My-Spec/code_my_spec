defmodule CodeMySpecSpex.Story1046.Criterion3176Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3176 — The preview app is up after a promotion, and is started if it
  is not.

  Rule: the running application must be serving the code that was promoted —
  a property of *promotion*, not of QA. Two scenarios below: an error is
  something QA is there to find, never a reason to hold a story back; and
  `promote` itself is what brings a down application back, restarting it as
  part of landing the merge.

  Story 1003, revised 2026-09-28: this file used to carry a third scenario,
  "A story is not ready for QA while its application is down" — refusing QA
  and routing to `PromoteWork` when the story's *own* copy (not main's
  post-promotion preview) wasn't answering. That was this criterion's
  business when `code_on_running_copy` sat upstream of `qa_complete` and QA
  tested main after promotion. Story 1003 reverses that order; the scenario
  moved to criterion 1169, rewritten to match what `QaStory` actually does
  now — brings the copy's own app up live as part of starting, and if that
  still fails, hands the task out anyway with a prompt saying so, never a
  graph-level refusal or a redirect to promotion. Caught by Harness
  (session 4298eb) before it shipped: offering `PromoteWork` there would have
  let an agent stamp `promoted_version` before `qa_complete` was satisfied.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import Phoenix.ChannelTest
  import CodeMySpecSpex.PromotionHelpers, only: [a_promotable_story: 1]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Promotion.Tools.PromoteSync
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  # The joins go through a real channel, which runs in a process of its own.
  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An application that answers with an error is QA's to find", criterion: 1183 do
    scenario "the application is up and returning 500s" do
      given_ "a story ready for QA, on the checkout the application runs from", context do
        context = CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)
        context = this_copy_is_the_running_one(context)
        {:ok, assign_story_to_this_copy(context)}
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

  spex "A down application is started by the same act that would promote to it",
    criterion: 1183 do
    scenario "the agent is working on the running copy and nothing is serving it" do
      given_ "an agent working on the checkout the application runs from", context do
        context = a_running_copy(context)
        story = a_promotable_story(context)

        CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex),
          at_head: true
        )

        {:ok, Map.put(context, :story, story)}
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
        response = promote(context, context.story.number)
        answer_restart_app(context.running_socket, context.running_root)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the application is started", context do
        # Polled, not asserted immediately: the restart is dispatched and never
        # awaited (54aa534c, phase two), so `promote` answering is not evidence
        # the recipe has run yet — only that it has been handed off.
        eventually(fn ->
          assert exists?(context.running_root, ".restarted"),
                 "the gate named `promote` as the way to bring a dead application " <>
                   "back, and promoting did not start it. Got: " <>
                   response_text(context.response)
        end)

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

    {running, running_socket} =
      join_working_copy_socket(context, running_root, "the checkout the dev app runs in")

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:running, running)
    |> Map.put(:running_socket, running_socket)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: running.working_copy_id})
  end

  # Through `promote_sync` rather than `promote`: both doors run the same
  # `Promotion.promote/1` and differ only in delivery, and the agent's door
  # returns before there is an outcome to assert on.
  defp promote(context, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
    {:reply, response, _frame} = PromoteSync.execute(%{story_number: story_number}, frame)
    response
  end

  # Standing in for the harness on the other end of `restart_app` — the
  # channel verb `Promotion.Runner.restart/3` now dispatches through
  # `WorkingCopies.AppTransport.restart_app/2`, the same one every working
  # copy's own app already answers to. Writing `.restarted` here, rather
  # than through a real `just restart`, is what `serve`'s own harness-side
  # launch would have done; a spec's job is proving the promotion asked for
  # it, not re-implementing the harness that answers.
  #
  # Dispatched detached (54aa534c, phase two), so this push can arrive a
  # moment after `promote/1` has already answered — the timeout is
  # generous for that gap, not for anything slow.
  defp answer_restart_app(socket, running_root) do
    assert_push "restart_app", %{"ref" => ref}, 5_000

    write(running_root, ".restarted", DateTime.to_string(DateTime.utc_now()))

    reply_ref =
      Phoenix.ChannelTest.push(socket, "restart_app_result", %{
        "ref" => ref,
        "status" => "ok",
        "app_status" => "serving",
        "app_url" => "http://127.0.0.1:4000",
        "app_commit" => "cafef00d"
      })

    receive do
      %Phoenix.Socket.Reply{ref: ^reply_ref, status: :ok} -> :ok
    after
      1_000 -> flunk("restart_app_result was never acknowledged")
    end
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

  # Story 1003: `Qa.complete_check/2,3` reads the *story's own* working copy
  # to know whether anything is serving before QA is offered — the half
  # `code_on_running_copy` used to cover for free by being upstream of
  # `qa_complete`. `FullSatisfactionFixtures.apply_story/1` never assigns a
  # copy, so it has to be set explicitly here.
  defp assign_story_to_this_copy(context) do
    story = Stories.get_story(context.scope, context.story.id)

    {:ok, story} =
      Stories.update_story(context.scope, story, %{
        working_copy_id: context.scope.active_working_copy_id
      })

    Map.put(context, :story, story)
  end
end
