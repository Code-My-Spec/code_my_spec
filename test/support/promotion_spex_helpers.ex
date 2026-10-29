defmodule CodeMySpecSpex.PromotionHelpers do
  @moduledoc """
  Promotion fixtures with distinct running, candidate, and gate checkouts.

  Candidates are certified at their actual revision. Scenarios that merge
  independent main work answer the gate explicitly before checking the
  requesting agent's landing notification.
  """

  import ExUnit.Assertions
  # `live/2` expands to `get/2`, which lives in ConnTest rather than LiveViewTest.
  import Phoenix.ConnTest, except: [delete: 2]
  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [push: 3, assert_reply: 4]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Analysis.Run
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.McpServers.Promotion.Tools.Promote
  alias CodeMySpec.PromotionQueue.Worker
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias CodeMySpecSpex.ProjectStateFixtures
  alias CodeMySpecSpex.StoryHelpers

  @endpoint CodeMySpecWeb.Endpoint

  @doc """
  A real story — no component link needed, since nothing this story's
  spex-passing check reads cares about one — with a passing BDD spec file
  synced for every one of its criteria. e1174640's own precondition for a
  `promote(story_number)` naming it to succeed: `Promotion.story_spex_pass/3`
  reads `Files.list_story_files/2` for the promoting working copy, and there
  must be at least one spec file there, none of them failing.

  `red?: true` records a failing spex problem against the story's own
  first criterion's file instead, for a scenario proving the refusal
  rather than the happy path — same file `story_spex_pass/3` would name.

  Promotable means QA has passed it: promotion comes after QA, and the queue
  refuses a story without a passing attempt. `qa: :not_passed` leaves it
  untested, for a scenario about that refusal; `qa: :certified` certifies it at
  the copy's HEAD and leaves it untested.

  `assigned?: true` assigns it to the promoting copy, as a team claiming it
  does: what an unnamed promote, and a copy's HEAD report, act on.
  """
  @spec a_promotable_story(map(), keyword()) :: map()
  def a_promotable_story(context, opts \\ []) do
    story =
      StoryHelpers.create_story(context.scope,
        title: Keyword.get(opts, :title, "Promotable story"),
        description: "As a user, I want this story's own code on the running copy.",
        acceptance_criteria: ["It works"]
      )

    :ok = ProjectStateFixtures.apply_bdd_spec_for_story(context, story)
    sync_story_specs_to_local_copy(context, story)
    story = if Keyword.get(opts, :assigned?, false), do: assign(context, story), else: story
    qa(context, story, Keyword.get(opts, :qa, :passed))

    if Keyword.get(opts, :red?, false) do
      [criterion | _] = story.criteria
      path = Fixtures.spec_file_path(story, criterion)

      {:ok, _} =
        Fixtures.record_problem(context.scope, "spex", %{
          file_path: path,
          message: "expected the war to be declared",
          severity: :error
        })
    end

    story
  end

  @doc "Certify the fixture story after a candidate commit and record the QA pass it reviewed."
  def certify_current_story(%{agent_root: root, story: story} = context) do
    :ok = StoryIssueBag.certify(context.scope, story.id, head_of(context, root))
    {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
    context
  end

  defp qa(%{agent_root: root} = context, story, :passed) do
    :ok =
      StoryIssueBag.certify(
        context.scope,
        story.id,
        head_of(context, root)
      )

    {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)
  end

  defp qa(context, story, :passed),
    do: {:ok, _} = Fixtures.passed_qa_attempt(context.scope, story_id: story.id)

  defp qa(%{agent_root: root} = context, story, :certified),
    do: :ok = StoryIssueBag.certify(context.scope, story.id, head_of(context, root))

  defp qa(_context, _story, :not_passed), do: :ok

  defp assign(context, story) do
    {:ok, _} =
      CodeMySpec.Stories.update_story(
        context.scope,
        CodeMySpec.Stories.get_story(context.scope, story.id),
        %{working_copy_id: context.scope.active_working_copy_id}
      )

    story
  end

  # The state fixture writes through the project's source environment.
  # Promotion reads spec evidence from the active copy, so publish these
  # generated files into that exact local checkout and commit only those paths.
  @doc """
  Mirror and commit a story's fixture BDD specs in the exact active local copy.

  Source environments without a corresponding local working-copy environment
  are left alone, preserving memory-only fixture scenarios.
  """
  def sync_story_specs_to_local_copy(%{scope: scope, execution_context: source}, story) do
    case WorkingCopies.execution_context(scope) do
      %ExecutionContext{type: :local, cwd: root} = local when is_binary(root) ->
        paths =
          Enum.map(story.criteria, fn criterion ->
            path = Fixtures.spec_file_path(story, criterion)
            {:ok, contents} = ExecutionContexts.read_file(source, path)
            :ok = ExecutionContexts.write_file(local, path, contents)
            path
          end)

        commit_fixture_specs(local, root, paths)
        :ok = Fixtures.sync_files(scope)

      _ ->
        :ok
    end
  end

  def sync_story_specs_to_local_copy(_context, _story), do: :ok

  @doc """
  Copy generated fixture files from the source environment into the selected
  local checkout, then publish their exact contents to Files.

  Only the fixture-owned roots are copied. A generated `mix.exs` is included
  only when the local checkout has none, because the boundary checker needs its
  app name to resolve the fixtures bridge path.
  """
  def materialize_source_fixture_files(%{scope: scope, execution_context: source}) do
    case WorkingCopies.execution_context(scope) do
      %ExecutionContext{type: :local, cwd: root} = local when is_binary(root) ->
        paths = source_fixture_paths(source, local)

        changed_paths =
          Enum.reduce(paths, [], fn path, changed ->
            copy_changed_fixture_file(source, local, path, changed)
          end)

        commit_fixture_paths(local, root, Enum.reverse(changed_paths))
        :ok = Fixtures.sync_files(scope)

      _ ->
        :ok
    end
  end

  def materialize_source_fixture_files(_context), do: :ok

  defp copy_changed_fixture_file(source, local, path, changed) do
    {:ok, contents} = ExecutionContexts.read_file(source, path)

    case ExecutionContexts.read_file(local, path) do
      {:ok, ^contents} ->
        changed

      _ ->
        :ok = ExecutionContexts.write_file(local, path, contents)
        [path | changed]
    end
  end

  defp source_fixture_paths(source, local) do
    fixture_paths =
      ExecutionContexts.stream_files(source, [".code_my_spec", "lib", "test", "config"])
      |> Enum.map(&Path.relative_to(&1, source.cwd))

    mix_file_paths =
      if ExecutionContexts.file_exists?(local, "mix.exs") or
           not ExecutionContexts.file_exists?(source, "mix.exs") do
        []
      else
        ["mix.exs"]
      end

    (fixture_paths ++ mix_file_paths)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp commit_fixture_specs(local, root, paths) do
    commit_fixture_paths(local, root, paths, "add promotion fixture specs")
  end

  defp commit_fixture_paths(_local, _root, []), do: :ok

  defp commit_fixture_paths(local, root, paths) do
    commit_fixture_paths(local, root, paths, "materialize promotion fixture setup")
  end

  defp commit_fixture_paths(local, root, paths, message) do
    {_, 0} = ExecutionContexts.cmd(local, "git", ["add", "--" | paths], cd: root)

    {_, 0} =
      ExecutionContexts.cmd(
        local,
        "git",
        ["commit", "-q", "-m", message, "--" | paths],
        cd: root
      )
  end

  @doc "Explicitly retain local bootstrap semantics for no-origin legacy fixtures."
  def local_bootstrap_project(context) do
    # These scenarios exercise the retained local/bootstrap promotion contract.
    # Remote publication scenarios use RemotePromotionHelpers and real origin.
    local_projects = Application.get_env(:code_my_spec, :local_promotion_projects, [])

    Application.put_env(:code_my_spec, :local_promotion_projects, [
      context.project.id | local_projects
    ])

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:code_my_spec, :local_promotion_projects, local_projects)
    end)

    context
  end

  @doc """
  A running checkout on `main` and an agent's worktree on `story/war`.

  Returns the context with `:running_root`, `:agent_root`, `:running`, `:agent`,
  and `:scope` repointed at the agent's copy — which is the scope a promoting
  agent actually holds.
  """
  def a_promotable_project(context, opts \\ []) do
    local_bootstrap_project(context)
    stop_the_queue_on_exit(context.project.id)
    running_root = CodeMySpec.TempFile.dir("spex-1046-running")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "mkdir", ["-p", running_root])

    {_, 0} = git(context, running_root, ["init", "--initial-branch", "main"])
    {_, 0} = git(context, running_root, ["config", "user.email", "spex@example.com"])
    {_, 0} = git(context, running_root, ["config", "user.name", "Spex"])

    write(running_root, "lib/broken_oaths/diplomacy/war.ex", war(":base"))
    write(running_root, ".gitignore", "/_build/\n")

    # The project's own restart recipe, which is the seam a promotion uses
    # instead of knowing how to bring a Phoenix app up. It compiles before it
    # records, because a real one does — so a merge that breaks the target is
    # caught by the application failing to come back rather than by an analyzer.
    write(running_root, "justfile", """
    restart:
        @elixirc -o {{justfile_directory()}}/_spex_build \\
            {{justfile_directory()}}/lib/broken_oaths/diplomacy/*.ex
        @date > {{justfile_directory()}}/.restarted
    """)

    {_, 0} = git(context, running_root, ["add", "-A"])
    {_, 0} = git(context, running_root, ["commit", "-q", "-m", "base"])
    # Released once, as a real project has been: promotions count from its tag.
    {_, 0} = git(context, running_root, ["tag", "-a", "v0.1.0", "-m", "v0.1.0"])

    # `worktree add` requires the path not to exist yet.
    agent_root = CodeMySpec.TempFile.dir("spex-1046-agent")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "rm", ["-rf", agent_root])

    {_out, 0} =
      git(context, running_root, ["worktree", "add", "-b", "story/war", agent_root, "main"])

    {running, running_socket} =
      join_main_working_copy_socket(
        context,
        running_root,
        "the checkout the dev app runs in",
        Keyword.take(opts, [:app_verbs])
      )

    # `agent_socket: true` keeps the copy's channel, for a scenario that plays
    # its harness reporting something.
    {agent, agent_socket} =
      if Keyword.get(opts, :agent_socket, false),
        do: join_local_working_copy_socket(context, agent_root, "the coding agent's copy"),
        else: {join_local_working_copy(context, agent_root, "the coding agent's copy"), nil}

    context = a_gate_copy(context, running_root)

    # The running checkout joined first and so holds the designation. Asserted,
    # because a promotion aimed at a copy that is not main is a promotion to
    # nowhere, and every scenario built on this would pass for the wrong reason.
    {:ok, _view, html} = live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    refute html =~
             ~s(phx-value-id="#{running.working_copy_id}" data-test="designate-main-copy"),
           "the premise failed: the running checkout is not this project's main copy"

    context
    |> Map.put(:running_root, running_root)
    |> Map.put(:agent_root, agent_root)
    |> Map.put(:running, running)
    |> Map.put(:running_socket, running_socket)
    |> Map.put(:agent, agent)
    |> Map.put(:agent_socket, agent_socket)
    |> Map.put(:scope, %{context.scope | active_working_copy_id: agent.working_copy_id})
  end

  # The queue's worker outlives the scenario under the application's
  # supervisor; stopped so a batch left gating does not reach for a sandbox
  # that is gone.
  @doc false
  def stop_the_queue_on_exit(project_id) do
    ExUnit.Callbacks.on_exit(fn ->
      case Registry.lookup(CodeMySpec.PromotionQueue.Registry, project_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(CodeMySpec.PromotionQueue.Supervisor, pid)
        [] -> :ok
      end
    end)
  end

  @doc """
  The project's promotion gate: a detached worktree of main that the queue
  builds and gates batches in. A real project's is minted on first need; here
  it is joined beside the running checkout, because the suite's minting host is
  a different repository.
  """
  def a_gate_copy(context, running_root) do
    gate_root = CodeMySpec.TempFile.dir("spex-1046-gate")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "rm", ["-rf", gate_root])
    {_, 0} = git(context, running_root, ["worktree", "add", "--detach", gate_root, "main"])

    {gate, socket} =
      join_local_working_copy_socket(context, gate_root, Worker.gate_label())

    context
    |> Map.put(:gate_root, gate_root)
    |> Map.put(:gate, Map.merge(gate, %{root: gate_root, id: gate.working_copy_id}))
    |> Map.put(:gate_socket, socket)
  end

  @doc """
  The gate copy's harness, played by the scenario: each analyzer run the queue
  dispatched to the gate is answered at the gate checkout's HEAD, the way a
  harness reports one — clean, or with the diagnostics in `findings` for the
  sources it names (`%{"compiler" => [%{"file" => ..., "line" => ...,
  "severity" => "error", "message" => ...}]}`).

  `sources:` is which runs to answer: every analyzer by default, one source for
  a re-run. Runs for other sources stay pending, for a later call to answer.
  """
  def the_gate_answers(context, findings \\ %{}, opts \\ []) do
    sources = Keyword.get(opts, :sources, Run.sources())
    runs = gate_runs(context.gate_socket, sources)
    # Read once the runs are here: the batch is built before they are sent.
    head = head_of(context, context.gate_root)

    for %{"run_id" => id, "source" => source} <- runs do
      diagnostics =
        if source == "exunit" do
          Enum.map(Fixtures.promotion_failure_paths(context.gate), fn file ->
            %{"file" => file, "line" => 1, "severity" => "error", "message" => "test failure"}
          end) ++ Map.get(findings, source, [])
        else
          Map.get(findings, source, [])
        end

      started = %{"run_id" => id, "start_commit" => head, "start_tree_dirty" => false}
      push(context.gate_socket, "analysis_started", started)

      ref =
        push(context.gate_socket, "analysis_result", %{
          "run_id" => id,
          "source" => source,
          "status" => "ok",
          "completed_commit" => head,
          "result" => raw_result(source, diagnostics)
        })

      assert_reply(ref, :ok, _, 10_000)
    end

    context
  end

  @doc "Answer a failed full gate and its failed-test rerun."
  def the_gate_answers_and_fails_rerun(context, findings) do
    the_gate_answers(context, findings)
    [%{"run_id" => id}] = gate_runs(context.gate_socket, ["exunit"])
    head = head_of(context, context.gate_root)
    diagnostics = Map.fetch!(findings, "exunit")

    push(context.gate_socket, "analysis_started", %{
      "run_id" => id,
      "start_commit" => head,
      "start_tree_dirty" => false
    })

    ref =
      push(context.gate_socket, "analysis_result", %{
        "run_id" => id,
        "source" => "exunit",
        "status" => "ok",
        "completed_commit" => head,
        "result" => raw_result("exunit", diagnostics)
      })

    assert_reply(ref, :ok, _, 10_000)
    context
  end

  @doc "Answer a failed full gate and a passing targeted ExUnit rerun."
  def the_gate_answers_and_passes_rerun(context, findings) do
    the_gate_answers(context, findings)
    [%{"run_id" => id}] = gate_runs(context.gate_socket, ["exunit"])
    head = head_of(context, context.gate_root)

    push(context.gate_socket, "analysis_started", %{
      "run_id" => id,
      "start_commit" => head,
      "start_tree_dirty" => false
    })

    ref =
      push(context.gate_socket, "analysis_result", %{
        "run_id" => id,
        "source" => "exunit",
        "status" => "ok",
        "completed_commit" => head,
        "result" => raw_result("exunit", [])
      })

    assert_reply(ref, :ok, _, 10_000)
    context
  end

  @doc """
  The sources the gate has been asked to run and has not been answered on,
  once it has been asked for `sources`. Leaves them pending.
  """
  def the_gate_is_running(context, sources \\ Run.sources()) do
    runs = gate_runs(context.gate_socket, sources)
    pending(context.gate_socket, runs)
    runs |> Enum.map(& &1["source"]) |> Enum.sort()
  end

  # The runs pushed to the gate's own channel for `wanted`. Other copies'
  # channels share the topic; the join ref tells them apart. Runs for other
  # sources are put back for a later call.
  defp gate_runs(socket, wanted), do: gate_runs(socket, wanted, [], [])

  defp gate_runs(socket, [], runs, others) do
    pending(socket, others)
    runs
  end

  defp gate_runs(%Phoenix.Socket{join_ref: join_ref} = socket, wanted, runs, others) do
    receive do
      %Phoenix.Socket.Message{
        event: "run_analysis",
        join_ref: ^join_ref,
        payload: %{"runs" => new}
      } ->
        {mine, theirs} = Enum.split_with(new, &(&1["source"] in wanted))

        gate_runs(
          socket,
          wanted -- Enum.map(mine, & &1["source"]),
          runs ++ mine,
          others ++ theirs
        )
    after
      30_000 -> flunk("the gate was never asked to run #{Enum.join(wanted, ", ")}")
    end
  end

  defp pending(_socket, []), do: :ok

  defp pending(%Phoenix.Socket{join_ref: join_ref, topic: topic}, runs) do
    send(self(), %Phoenix.Socket.Message{
      event: "run_analysis",
      join_ref: join_ref,
      topic: topic,
      payload: %{"runs" => runs}
    })

    :ok
  end

  defp raw_result("exunit", diagnostics),
    do: %{
      "execution_status" => if(diagnostics == [], do: "success", else: "failure"),
      "exit_status" => if(diagnostics == [], do: 0, else: 2),
      "stats" => %{"tests" => 1 + length(diagnostics), "failures" => length(diagnostics)},
      "diagnostics" => diagnostics
    }

  defp raw_result(_source, diagnostics),
    do: %{"exit_status" => if(diagnostics == [], do: 0, else: 1), "diagnostics" => diagnostics}

  @doc "An agent on the coding agent's copy, which `promote/2` then promotes as."
  def an_agent_on_the_copy(context) do
    # Running, so present: the queue's outcome is delivered only to an agent
    # whose process is up.
    agent =
      Fixtures.running_agent(
        %{context.scope | active_working_copy_id: context.agent.working_copy_id},
        provider: "anthropic",
        working_copy: context.agent_root
      )

    # Running is presence now (e3042a7c's sibling gap): the queue's outcome
    # delivery checks `Presence.present?/2`, and this row alone reads as off.
    Fixtures.mark_present(agent)

    Map.put(context, :agent_id, agent.id)
  end

  @doc "What the queue told the promoting agent, once it had decided."
  def what_the_agent_was_told(context, timeout \\ 30_000),
    do: what_was_told(context.agent_id, timeout)

  @doc "What the queue told `agent_id`, once it had decided."
  def what_was_told(agent_id, timeout \\ 30_000) do
    receive do
      {:agent_dispatch, ^agent_id, _ref, message} -> message
    after
      timeout -> flunk("the promoting agent was never told what became of its promotion")
    end
  end

  @doc """
  Another agent's copy: a worktree of the running checkout on its own branch
  from `from`, joined, with an agent on it. Put in `context` under `key` as
  `%{root:, scope:, agent_id:, working_copy_id:}`.
  """
  def another_candidate(context, key, from \\ "main") do
    root = CodeMySpec.TempFile.dir("spex-1046-#{key}")
    {_, 0} = ExecutionContexts.cmd(context.execution_context, "rm", ["-rf", root])

    {_, 0} =
      git(context, context.running_root, ["worktree", "add", "-b", "story/#{key}", root, from])

    copy = join_local_working_copy(context, root, "#{key}'s copy")
    scope = %{context.scope | active_working_copy_id: copy.working_copy_id}

    agent = Fixtures.running_agent(scope, provider: "anthropic", working_copy: root)

    # Running is presence now (e3042a7c's sibling gap), same as above.
    Fixtures.mark_present(agent)

    Map.put(context, key, %{
      root: root,
      scope: scope,
      agent_id: agent.id,
      working_copy_id: copy.working_copy_id
    })
  end

  @doc "Write `path` in the checkout at `root` and commit it."
  def commit_work(context, root, path, content) do
    write(root, path, content)
    {_, 0} = git(context, root, ["add", "-A"])
    {_, 0} = git(context, root, ["commit", "-q", "-m", "work on #{path}"])
    context
  end

  @doc """
  The agent's copy with a commit of its own, as a copy promoting a story has.
  A copy still at main's commit is already on main, and the queue lands it
  without a gate (2583cc8b0), so nothing would certify or latch it.
  """
  def with_work_on_the_copy(context),
    do:
      commit_work(
        context,
        context.agent_root,
        "lib/story_work.ex",
        "defmodule StoryWork do\nend\n"
      )

  @doc "A candidate's own analyzers current at its HEAD."
  def its_analyzers_are_current(context, %{scope: scope}) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(scope, Run.sources(), at_head: true)

    context
  end

  @doc "Promote from `candidate`'s copy, as its agent."
  def promote_from(%{scope: scope, agent_id: agent_id}, story_number) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope, agent_id: agent_id}}
    {:reply, response, _frame} = Promote.execute(%{story_number: story_number}, frame)
    response
  end

  @doc """
  Both copies' analyzers current.

  A real precondition rather than scaffolding: the gate will not call a copy
  clean at a commit no run answers for, so any scenario about what happens
  *after* the gate opens has to say that it opens.
  """
  def analyzers_are_current(context) do
    CodeMySpecSpex.Fixtures.fresh_analysis_runs(context.scope, ~w(compiler credo exunit spex),
      at_head: true
    )

    CodeMySpecSpex.Fixtures.fresh_analysis_runs(
      %{context.scope | active_working_copy_id: context.running.working_copy_id},
      ~w(compiler credo exunit spex),
      at_head: true
    )

    context
  end

  @doc """
  Promote, through `promote` — the door an agent actually uses.

  This drove `promote_sync` instead, and the reason it gave was the defect:
  "`promote` answers at once and messages the outcome back, which leaves a spec
  nothing in the reply to assert on". True, and it meant every criterion on this
  story asserted against the *other* tool. `Promotion.promote/1` always returned
  its refusals correctly, so all nineteen passed while the tool agents call
  answered "Promotion started." to a promotion it had already refused — and for
  any caller without an Alloy conversation, that false success was the only
  thing they ever got.

  A spec that cannot assert on a surface is a reason to fix the surface. `promote`
  is synchronous now — nothing in it is long-running, the restart was already
  detached — so it answers, and these criteria cover the door that is used.
  """
  def promote(context, story_number), do: promote(context, story_number, [])

  def promote(context, story_number, opts) do
    frame = %Anubis.Server.Frame{
      assigns: %{current_scope: context.scope, agent_id: Map.get(context, :agent_id)}
    }

    args = Map.merge(%{story_number: story_number, fresh: false}, Map.new(opts))
    {:reply, response, _frame} = Promote.execute(args, frame)
    response
  end

  @doc "An explicit `:cd` wins over the environment's own cwd, which is what lets one environment drive two checkouts."
  def git(context, dir, args),
    do:
      ExecutionContexts.cmd(context.execution_context, "git", args,
        cd: dir,
        stderr_to_stdout: true
      )

  @doc "The commit a checkout is on."
  def head_of(context, root) do
    {out, 0} = git(context, root, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  @doc "A module whose body the scenario controls, so a merge has something to carry."
  def war(body) do
    "defmodule BrokenOaths.Diplomacy.War do\n  def declare, do: #{body}\nend\n"
  end

  @doc "A second module, for giving main a commit the story branch does not have."
  def treaty do
    "defmodule BrokenOaths.Diplomacy.Treaty do\n  def sign, do: :signed\nend\n"
  end

  def disk(root), do: ExecutionContext.new(:local, root)

  def write(root, path, content),
    do: :ok = ExecutionContexts.write_file(disk(root), path, content)

  def read(root, path) do
    {:ok, contents} = ExecutionContexts.read_file(disk(root), path)
    contents
  end

  def exists?(root, path), do: ExecutionContexts.file_exists?(disk(root), path)

  @doc """
  Join a promotion checkout and register its real local disk environment by working copy ID.
  """
  def join_local_working_copy(context, root, label, opts \\ []) do
    copy = join_working_copy(context, root, label, opts)
    register_disk_environment(copy, root)
    copy
  end

  @doc """
  Join a promotion checkout with its channel and register its local disk environment.
  """
  def join_local_working_copy_socket(context, root, label, opts \\ []) do
    {copy, socket} = join_working_copy_socket(context, root, label, opts)
    register_disk_environment(copy, root)
    {copy, socket}
  end

  @doc "Join the scenario's running checkout and explicitly designate it as main."
  def join_main_working_copy(context, root, label, opts \\ []) do
    copy = join_local_working_copy(context, root, label, opts)
    :ok = Fixtures.designate_main(context.scope, copy.working_copy_id)
    copy
  end

  @doc "Join the running checkout with its channel, register it locally, and designate it as main."
  def join_main_working_copy_socket(context, root, label, opts \\ []) do
    {copy, socket} = join_local_working_copy_socket(context, root, label, opts)
    :ok = Fixtures.designate_main(context.scope, copy.working_copy_id)
    {copy, socket}
  end

  defp register_disk_environment(copy, root) do
    key = {:working_copy, copy.working_copy_id}
    :ok = ExecutionContexts.unregister(key)
    :ok = ExecutionContexts.register(key, disk(root))
    :ok
  end
end
