defmodule CodeMySpec.Requirements.TheGraphRecomputesWhenItsInputsMoveTest do
  @moduledoc """
  A write to the graph's inputs reaches the agent waiting on it.

  Every graph computation in this application used to be triggered by a
  *reader* — a LiveView, `get_next_requirement`, the stop menu. Nothing computed
  on a write and nothing computed on a schedule, so an agent that was not
  reading never learned that work had appeared.

  Watched on 2026-09-07: a product agent stopped correctly with an empty queue —
  "No product work is currently available; I'll stop and wait to be woken when a
  product requirement is unblocked" — and sat for ninety minutes while four
  issues were filed and `issues_triaged` became actionable again.

  The first fix was a proxy: wake the roles when an issue is created. John:
  "I'd prefer not to add special cases... writer side events are the way I
  think. At least the logic is centralized and reads are reads."

  So writers announce, one watcher per project debounces and asks the
  fingerprint, and the recompute happens in one place.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)

    RecordingAgentTransport.listen()

    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    %{scope: scope, copy: copy}
  end

  defp product_agent(scope, copy) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: true,
        working_copy: "/tmp/watch-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        scope.active_account_id,
        scope.active_project_id,
        agent.id
      )

    agent
  end

  defp woken(acc \\ []) do
    receive do
      {:agent_dispatch, id, _ref, message} -> woken([{id, message} | acc])
    after
      500 -> acc
    end
  end

  test "filing an issue reaches a product agent that had stopped", ctx do
    product = product_agent(ctx.scope, ctx.copy)
    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "something is wrong",
        description: "filed while product was idle",
        severity: :medium
      })

    # `settle/1` is the debounce made deterministic: it does the pending pass
    # now instead of in two seconds. A test that slept would be asserting the
    # timer rather than the mechanism.
    :ok = GraphWatcher.settle(ctx.scope)

    assert Enum.any?(woken(), fn {id, message} ->
             id == product.id and message =~ "Work of your kind is available"
           end),
           """
           An issue was filed, the graph moved, and the role that triages it heard
           nothing. This is the ninety minutes of silence: the agent said it would
           wait to be woken when a product requirement was unblocked, and filing an
           issue is exactly that happening.
           """
  end

  test "a write announces on the project's graph topic", ctx do
    GraphInputs.subscribe(ctx.scope.active_project_id)

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "another",
        description: "d",
        severity: :low
      })

    assert_receive {:graph_inputs_changed, project_id}, 1_000
    assert project_id == ctx.scope.active_project_id
  end

  # The harness's own path, and the one that carries most real change. A scan
  # arrives as a manifest and lands in `reconcile/2`, never in `sync/2` — so
  # hooking only the latter announced nothing for any file an agent wrote.
  # Measured on dev: fifteen reconciles after the watcher shipped, and not one
  # announcement.
  test "a harness manifest announces when it changed something", ctx do
    GraphInputs.subscribe(ctx.scope.active_project_id)

    CodeMySpec.Files.FileSync.reconcile(ctx.scope, [
      %{
        path: "lib/example/thing.ex",
        role: :implementation,
        mtime: DateTime.utc_now(),
        size: 42,
        fingerprint: "abc123"
      }
    ])

    assert_receive {:graph_inputs_changed, _project_id}, 1_000
  end

  test "a manifest that changed nothing stays quiet", ctx do
    GraphInputs.subscribe(ctx.scope.active_project_id)

    CodeMySpec.Files.FileSync.reconcile(ctx.scope, [])

    refute_receive {:graph_inputs_changed, _project_id}, 300
  end

  test "the watcher says when the graph has been recomputed", ctx do
    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)
    GraphInputs.subscribe(ctx.scope.active_project_id)

    GraphInputs.changed(ctx.scope)
    :ok = GraphWatcher.settle(ctx.scope)

    assert_receive {:graph_updated, project_id}, 2_000
    assert project_id == ctx.scope.active_project_id
  end

  # The two properties that keep the wake from being a broadcast. They belonged
  # to the issue-creation proxy this replaced; the proxy is gone and they are
  # still true of `wake_project_roles/2`, which is what the watcher calls.
  test "an agent that is not in the loop is left alone", ctx do
    {:ok, stopped} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "product",
        continuous: false,
        working_copy: "/tmp/stopped-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)
    GraphInputs.changed(ctx.scope)
    :ok = GraphWatcher.settle(ctx.scope)

    refute Enum.any?(woken(), fn {id, _message} -> id == stopped.id end),
           "an agent outside the loop was woken by a change it never asked about"
  end

  test "a role with nothing of its own is not charged a turn", ctx do
    {:ok, qa} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "qa",
        continuous: true,
        working_copy: "/tmp/qa-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.copy.id
      })

    {:ok, _} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        qa.id
      )

    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)

    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{title: "t", description: "d", severity: :medium})

    :ok = GraphWatcher.settle(ctx.scope)

    refute Enum.any?(woken(), fn {id, _message} -> id == qa.id end),
           "QA has no issue-triage requirement and was woken to be told so"
  end

  # One watcher per project, however many callers ask for one.
  test "watching is idempotent", ctx do
    {:ok, first} = GraphWatcher.ensure_watching(ctx.scope)
    {:ok, second} = GraphWatcher.ensure_watching(ctx.scope)

    assert first == second
  end

  # Watchers are in memory, so a restart takes them all — and a deploy is exactly
  # when agents are mid-run. Without this an agent that went idle after one had
  # nothing watching for the work that would wake it, and the only way back was
  # a human toggling a loop.
  test "a restart re-establishes a watcher for a project being worked", ctx do
    _product = product_agent(ctx.scope, ctx.copy)

    assert :ok = GraphWatcher.watch_active_projects()

    assert [{_pid, _}] =
             Registry.lookup(CodeMySpec.Requirements.Registry, ctx.scope.active_project_id)
  end

  test "a project nobody is working is left unwatched", ctx do
    assert :ok = GraphWatcher.watch_active_projects()

    assert [] = Registry.lookup(CodeMySpec.Requirements.Registry, ctx.scope.active_project_id),
           "a project with no agent in the loop needs no watcher"
  end

  # `settle/1` is called from the agent-facing read on every stop, so a project
  # nobody is watching must not turn that into an error or a wait.
  test "settling a project with no watcher is fine", ctx do
    assert :ok = GraphWatcher.settle(ctx.scope)
  end

  test "settling with nothing pending is fine", ctx do
    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)

    assert :ok = GraphWatcher.settle(ctx.scope)
  end

  # The deadlock this was written against: waking renders each role's menu, the
  # menu counts requirements, and the count calls `settle/1` — which is a call
  # to the watcher. Waking inline would be the watcher calling itself.
  test "a recompute that wakes an agent does not deadlock on its own settle", ctx do
    _product = product_agent(ctx.scope, ctx.copy)
    {:ok, _pid} = GraphWatcher.ensure_watching(ctx.scope)

    GraphInputs.changed(ctx.scope)

    assert :ok = GraphWatcher.settle(ctx.scope)
    assert :ok = GraphWatcher.settle(ctx.scope), "the watcher survived its own recompute"
  end
end
