defmodule CodeMySpec.Agents.CompletionHandoffsTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Agents.{AgentsRepository, CompletionHandoffs}
  alias CodeMySpec.Agents.Main.Digest
  alias CodeMySpecTest.{AgentPresence, RecordingAgentTransport}
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    scope = full_scope_fixture()
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    {:ok, main_copy} = CodeMySpec.WorkingCopies.issue(scope, nil, device: device)
    {:ok, copy} = CodeMySpec.WorkingCopies.issue(scope, nil, device: device)
    {:ok, _} = CodeMySpec.WorkingCopies.designate_main(scope, main_copy.id)

    agents =
      Enum.map([{"main", main_copy}, {"coding", copy}], fn {role, working_copy} ->
        {:ok, agent} =
          AgentsRepository.create_agent(scope, %{
            role: role,
            status: :running,
            provider: "anthropic",
            engine: :alloy,
            working_copy_id: working_copy.id,
            working_copy: "/tmp/handoff-#{System.unique_integer([:positive])}"
          })

        AgentPresence.present(agent)
      end)

    [main, owner] = agents
    task = Ecto.UUID.generate()

    {:ok, handoff} =
      CompletionHandoffs.assign(scope, main.id, %{
        owner_agent_id: owner.id,
        working_copy_id: copy.id,
        task_id: task,
        identity: "reviewed-docs",
        artifact_paths: [".code_my_spec/knowledge/review.md"],
        reviewed_base: String.duplicate("a", 40),
        reviewed_diff: "Reviewed documentation delta",
        purpose: "Preserve reviewed docs",
        next_action: "Main reviews the gitlink before promotion"
      })

    evidence = %{
      artifact_sha: String.duplicate("b", 40),
      parent_gitlink: String.duplicate("b", 40),
      parent_commit: String.duplicate("c", 40),
      verification: "Parent gitlink matches preserved artifact"
    }

    %{
      scope: scope,
      main: main,
      owner: owner,
      copy: copy,
      task: task,
      handoff: handoff,
      evidence: evidence
    }
  end

  test "completion is durable and duplicate reports do not create another handoff", ctx do
    assert {:ok, completed} =
             CompletionHandoffs.complete(
               ctx.scope,
               ctx.owner.id,
               ctx.task,
               ctx.handoff.id,
               ctx.evidence
             )

    assert completed.status == :completed

    assert {:ok, same} =
             CompletionHandoffs.complete(
               ctx.scope,
               ctx.owner.id,
               ctx.task,
               ctx.handoff.id,
               ctx.evidence
             )

    assert same.id == completed.id
    assert [pending] = CompletionHandoffs.pending(ctx.scope)
    assert pending.artifact_sha == ctx.evidence.artifact_sha
    assert pending.delivery_state == :queued
    assert is_nil(pending.delivery_error)
    refute Digest.quiet?(%Digest{completions: [pending]})

    assert {:error, :conflicting_completion} =
             CompletionHandoffs.complete(ctx.scope, ctx.owner.id, ctx.task, ctx.handoff.id, %{
               ctx.evidence
               | verification: "Different evidence"
             })
  end

  test "receipt is not acknowledgement and only main can release the artifact gate", ctx do
    assert {:error, _} =
             CodeMySpec.Promotion.HandoffGate.check(ctx.scope.active_project_id, ctx.copy.id)

    {:ok, _} =
      CompletionHandoffs.complete(ctx.scope, ctx.owner.id, ctx.task, ctx.handoff.id, ctx.evidence)

    assert_receive {:agent_dispatch, _, _, message}
    assert message =~ "receipt alone is not acknowledgement"
    assert [_] = CompletionHandoffs.pending(ctx.scope)

    assert {:error, :only_project_main} =
             CompletionHandoffs.acknowledge(ctx.scope, ctx.owner.id, ctx.handoff.id, "Reviewed")

    assert {:ok, acknowledged} =
             CompletionHandoffs.acknowledge(
               ctx.scope,
               ctx.main.id,
               ctx.handoff.id,
               "Reviewed artifact and gitlink; next owner is main"
             )

    assert acknowledged.status == :acknowledged
    assert CompletionHandoffs.pending(ctx.scope) == []
    assert :ok = CodeMySpec.Promotion.HandoffGate.check(ctx.scope.active_project_id, ctx.copy.id)
  end

  test "wrong owner, wrong task and mismatched gitlink cannot report completion", ctx do
    assert {:error, :not_assigned_owner_or_task} =
             CompletionHandoffs.complete(
               ctx.scope,
               ctx.main.id,
               ctx.task,
               ctx.handoff.id,
               ctx.evidence
             )

    assert {:error, :not_assigned_owner_or_task} =
             CompletionHandoffs.complete(
               ctx.scope,
               ctx.owner.id,
               "another-task",
               ctx.handoff.id,
               ctx.evidence
             )

    assert {:error, :gitlink_does_not_match_artifact} =
             CompletionHandoffs.complete(ctx.scope, ctx.owner.id, ctx.task, ctx.handoff.id, %{
               ctx.evidence
               | parent_gitlink: String.duplicate("d", 40)
             })
  end

  test "a completion recorded while main is absent is recovered on reconnect without acknowledgement",
       ctx do
    AgentPresence.absent(ctx.main)

    assert {:ok, _} =
             CompletionHandoffs.complete(
               ctx.scope,
               ctx.owner.id,
               ctx.task,
               ctx.handoff.id,
               ctx.evidence
             )

    assert [undelivered] = CompletionHandoffs.pending(ctx.scope)
    assert undelivered.delivery_state == :failed
    assert undelivered.delivery_error == ":main_unavailable"
    refute_receive {:agent_dispatch, _, _, _}, 100
    AgentPresence.present(ctx.main)
    CompletionHandoffs.recover(ctx.scope, ctx.main.working_copy_id)
    assert_receive {:agent_dispatch, id, _, message}, 1000
    assert id == ctx.main.id
    assert message =~ ctx.handoff.id
    assert [pending] = CompletionHandoffs.pending(ctx.scope)
    assert pending.status == :completed
    assert pending.delivery_state == :queued
    assert is_nil(pending.delivery_error)
    assert is_nil(pending.acknowledged_at)
  end

  test "another project cannot read or complete the handoff", ctx do
    other = full_scope_fixture()
    assert CompletionHandoffs.list(other) == []

    assert {:error, :handoff_not_found} =
             CompletionHandoffs.complete(
               other,
               ctx.owner.id,
               ctx.task,
               ctx.handoff.id,
               ctx.evidence
             )
  end
end
