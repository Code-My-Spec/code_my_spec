defmodule CodeMySpec.AgentTasks.CompletingStoryPromotedIsThePromotionTest do
  @moduledoc """
  28d72f8a, chunk 3: promotion lives inside the story_promoted task.

  Its prompt lists every problem the gate would block on and says to fix them
  and complete; it no longer tells the agent to call `promote`. Completing
  (`evaluate/3`, what `evaluate_task` calls) runs the promotion itself:
  promoted is valid, pending keeps the task open and wakes the agent when the
  runs land (its own or ones already running at HEAD), refused keeps it open
  with the reason.

  Git is scripted through the in-memory environment's per-env shell; nothing
  shells out.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.AgentTasks.PromoteWork
  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Analysis.Reconciler
  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.AnalysisFixtures
  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Support.InMemoryEnvironment
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecTest.RecordingAgentTransport
  alias Ecto.Adapters.SQL.Sandbox

  @main "/story-promoted/main"
  @agent "/story-promoted/agent"
  @main_head "1111111111111111111111111111111111111111"
  @head "2222222222222222222222222222222222222222"

  defp script(git) do
    test = self()

    fn "git", args, opts ->
      cd = Keyword.fetch!(opts, :cd)
      send(test, {:git, cd, args})
      answer(git, cd, args)
    end
  end

  defp answer(%{contains_main: true}, @agent, ["merge-base", "--is-ancestor", @main_head, "HEAD"]),
       do: {"", 0}

  defp answer(%{contains_main: false}, @agent, ["merge-base", "--is-ancestor", @main_head, "HEAD"]),
       do: {"", 1}

  defp answer(git, @agent, ["status" | _]), do: {git.status, 0}
  defp answer(_git, @agent, ["rev-parse", "--abbrev-ref", "HEAD"]), do: {"story/x\n", 0}
  defp answer(_git, @agent, ["rev-parse", "HEAD"]), do: {@head <> "\n", 0}
  defp answer(_git, @agent, ["ls-files" | _]), do: {"", 0}
  defp answer(_git, @main, ["rev-parse", "HEAD"]), do: {@main_head <> "\n", 0}
  defp answer(_git, @main, ["diff" | _]), do: {"", 0}
  defp answer(_git, @main, ["merge", "--ff-only", @head]), do: {"Already up to date.\n", 0}

  defp answer(_git, @main, ["show", "HEAD:mix.exs"]),
    do: {~s|def project, do: [app: :x, version: "0.3.3"]\n|, 0}

  defp answer(_git, cd, args), do: {"unscripted: git #{Enum.join(args, " ")} in #{cd}", 1}

  defp a_running_app(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "main-harness", @main)
      send(test, :registered)

      receive do
        {:"$gen_call", from, {:restart_app, _request}} ->
          GenServer.reply(from, {:ok, %{status: "serving", url: "http://x", commit: @head}})
      end
    end)

    assert_receive :registered, 2_000
  end

  # The promoting copy's harness: every run dispatched to it is forwarded.
  defp a_harness(working_copy_id) do
    test = self()

    spawn(fn ->
      :ok = HarnessRegistry.register_executor(working_copy_id, "agent-harness", @agent)
      send(test, :registered)
      forward(test)
    end)

    assert_receive :registered, 2_000
  end

  defp forward(test) do
    receive do
      {:run_analysis, runs} -> send(test, {:dispatched, runs})
      _other -> :ok
    end

    forward(test)
  end

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()

    # A promotion's restart tells the agent from a detached task.
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp a_project(git \\ []) do
    git = Map.merge(%{contains_main: true, status: ""}, Map.new(git))
    scope = full_scope_fixture()

    {:ok, running} = WorkingCopies.issue(scope, nil, label: "main", device: device_fixture(scope))
    {:ok, running} = WorkingCopies.report_root(running, @main)
    a_running_app(running.id)

    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "agent", device: device_fixture(scope))
    {:ok, copy} = WorkingCopies.report_root(copy, @agent)
    a_harness(copy.id)

    {:ok, env} = InMemoryEnvironment.create(shell: script(git))
    scope = %{scope | active_working_copy_id: copy.id, environment: env}

    {:ok, coder} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        working_copy: @agent,
        working_copy_id: copy.id
      })

    story = story_fixture(scope, %{title: "The war is declared"})
    spex = "test/spex/#{story.number}_feature/criterion_1_spex.exs"

    {_n, _} =
      Files.upsert_files(scope, [
        %{path: spex, role: :bdd_spec, story_id: story.id, valid: true, mtime: DateTime.utc_now()}
      ])

    %{scope: scope, copy: copy, coder: coder, story: story, task: %{story_id: story.id}}
  end

  defp certified(scope, sources \\ Run.sources()),
    do: AnalysisFixtures.fresh_analysis_runs_fixture(scope, sources, commit: @head)

  defp dispatched_sources do
    receive do
      {:dispatched, runs} -> Enum.map(runs, & &1["source"]) ++ dispatched_sources()
    after
      100 -> []
    end
  end

  # The result arriving, as the harness channel reconciles it: the run re-read
  # at arrival, then reconciled.
  defp lands(scope, source) do
    [run] = RunsRepository.running_full_runs(scope, source)

    Reconciler.reconcile(scope, Repo.get!(Run, run.id), %{
      problems: [],
      output: "done",
      exit_status: 0,
      stats: %{}
    })
  end

  # The detached restart task records what it told the agent after telling it.
  defp settled do
    for pid <- Task.Supervisor.children(CodeMySpec.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp told(agent_id) do
    receive do
      {:agent_dispatch, ^agent_id, _ref, message} -> [message | told(agent_id)]
    after
      200 -> []
    end
  end

  describe "the prompt" do
    test "lists the problems the gate would block on and says to complete, not promote" do
      %{scope: scope, task: task} = a_project()

      problem_fixture(scope, %{
        source: "credo",
        severity: :warning,
        file_path: "lib/war.ex",
        line: 12,
        message: "Nested modules could be aliased"
      })

      problem_fixture(scope, %{source: "credo", severity: :info, message: "advisory only"})

      {:ok, prompt} = PromoteWork.command(scope, task)

      assert prompt =~ "credo (1)"
      assert prompt =~ "lib/war.ex:12: Nested modules could be aliased"
      refute prompt =~ "advisory only", ":info never blocks, so it is not listed"
      assert prompt =~ "Fix them all"
      assert prompt =~ "evaluate_task"
      refute prompt =~ "`promote`", "the agent no longer calls promote. Got: #{prompt}"
    end

    test "says so when nothing blocks" do
      %{scope: scope, task: task} = a_project()

      {:ok, prompt} = PromoteWork.command(scope, task)

      assert prompt =~ "No problem that would block the promotion"
      refute prompt =~ "`promote`"
    end
  end

  describe "completing" do
    test "a clean HEAD merges exactly that commit, stamps the story, and is valid" do
      %{scope: scope, coder: coder, story: story, task: task} = a_project()
      certified(scope)

      assert {:ok, :valid, _text} = PromoteWork.evaluate(scope, task, coder)

      assert_received {:git, @main, ["merge", "--ff-only", @head]}
      assert Stories.get_story!(scope, story.id).promoted_version == "0.3.3"
      assert {:ok, :valid, _} = PromoteWork.evaluate(scope, task)

      coder_id = coder.id
      assert_receive {:agent_dispatch, ^coder_id, _ref, confirmed}, 2_000
      assert confirmed =~ "restart from your promotion is confirmed"
      settled()
    end

    test "a story already stamped is valid without promoting again" do
      %{scope: scope, coder: coder, story: story, task: task} = a_project()
      {:ok, _} = Stories.mark_story_promoted(scope, story, "0.3.2", commit: @head)

      assert {:ok, :valid, _} = PromoteWork.evaluate(scope, task, coder)
      refute_received {:git, _, _}
    end

    test "missing runs are started, the task stays open, and the agent is woken as they land" do
      %{scope: scope, copy: copy, coder: coder, story: story, task: task} = a_project()
      certified(scope, ["compiler", "credo"])

      assert {:ok, :pending, text} = PromoteWork.evaluate(scope, task, coder)
      assert text =~ "analysis running at #{@head}"
      assert text =~ "evaluate_task"
      refute text =~ "`promote`"

      assert Enum.sort(dispatched_sources()) == ["exunit", "spex"]
      refute_received {:git, @main, ["merge" | _]}
      assert Stories.get_story!(scope, story.id).promoted_version == nil

      assert Analysis.awaiting_runs?(scope, copy.id, coder.id),
             "the agent waiting on its promotion's runs must not be nudged"

      lands(scope, "exunit")
      assert [message] = told(coder.id)
      assert message =~ "exunit run finished"
    end

    test "a run already in flight at HEAD counts, and wakes the agent when it lands" do
      %{scope: scope, copy: copy, coder: coder, task: task} = a_project()
      certified(scope, ["compiler", "exunit", "spex"])

      someone_else = Ecto.UUID.generate()

      {:ok, credo} =
        RunsRepository.start_run(scope, %{
          source: "credo",
          kind: :full,
          requested_by: %{kind: "hook", agent_id: someone_else}
        })

      RunsRepository.record_tree(credo, %{start_commit: @head, start_tree_dirty: false})

      refute Analysis.awaiting_runs?(scope, copy.id, coder.id)

      assert {:ok, :pending, text} = PromoteWork.evaluate(scope, task, coder)
      assert text =~ "credo"
      assert dispatched_sources() == [], "no second run for the same commit"

      assert Analysis.awaiting_runs?(scope, copy.id, coder.id),
             "a run somebody else started at HEAD is the promoting agent's wait too"

      # Asking again does not add it twice.
      assert {:ok, :pending, _} = PromoteWork.evaluate(scope, task, coder)
      assert Repo.get!(Run, credo.id).requested_by["waiters"] == [coder.id]

      lands(scope, "credo")

      assert [message] = told(coder.id)
      assert message =~ "credo run finished"
      refute Analysis.awaiting_runs?(scope, copy.id, coder.id)
    end

    test "a copy behind main is refused and the task stays open with the reason" do
      %{scope: scope, coder: coder, task: task} = a_project(contains_main: false)

      assert {:ok, :invalid, feedback} = PromoteWork.evaluate(scope, task, coder)
      assert feedback =~ "behind main"
      assert feedback =~ "evaluate_task"
      assert dispatched_sources() == []
    end

    test "a dirty tree is refused, naming the files" do
      %{scope: scope, coder: coder, task: task} = a_project(status: " M lib/war.ex\n")

      assert {:ok, :invalid, feedback} = PromoteWork.evaluate(scope, task, coder)
      assert feedback =~ "lib/war.ex"
      refute_received {:git, @main, ["merge" | _]}
    end

    test "problems at HEAD refuse, and nothing merges" do
      %{scope: scope, coder: coder, story: story, task: task} = a_project()
      certified(scope)
      problem_fixture(scope, %{source: "credo", severity: :warning})

      assert {:ok, :invalid, feedback} = PromoteWork.evaluate(scope, task, coder)
      assert feedback =~ "1 credo"
      refute_received {:git, @main, ["merge" | _]}
      assert Stories.get_story!(scope, story.id).promoted_version == nil
    end
  end

  test "the promote tool's path without a story still merges and stamps nothing" do
    %{scope: scope, story: story} = a_project()
    certified(scope)

    assert {:ok, %{merged: "story/x"} = result} = Promotion.promote(scope, nil, notify: nil)
    refute Map.has_key?(result, :story)
    assert Stories.get_story!(scope, story.id).promoted_version == nil
    settled()
  end
end
