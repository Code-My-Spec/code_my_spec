defmodule CodeMySpec.Agents.AWaitingAgentIsNeitherNudgedNorWokenTest do
  @moduledoc """
  An agent waiting on something that messages it when it lands is not told
  anything at turn end and is not offered a turn — `Agents.Waiting` is the one
  list both paths read.

  1599c109: an agent that started a provisioning step and ended its turn to
  wait was nudged meanwhile; the step's own finish message is what wakes it.
  """

  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.StopDecision
  alias CodeMySpec.Agents.Waiting
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Environments
  alias CodeMySpec.Notifications.QuestionRequest
  alias CodeMySpec.Provisioning.RunLock
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    RecordingAgentTransport.listen(ctx)

    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)
    :ok = GraphWatcher.settle(ctx.scope)

    {:ok, agent} =
      AgentsRepository.create_agent(ctx.scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        status: :running,
        working_copy: "/tmp/waiting-#{System.unique_integer([:positive])}",
        working_copy_id: ctx.scope.active_working_copy_id
      })

    AgentPresence.present(agent)

    on_exit(fn -> :persistent_term.erase({StopDecision, :decision, agent.id}) end)

    {:ok, _conversation} =
      CodeMySpec.Conversations.find_or_create_agent_conversation(
        ctx.scope.active_account_id,
        ctx.scope.active_project_id,
        agent.id
      )

    Map.put(ctx, :agent, agent)
  end

  # A run in another process, as the real one is: the lock lives as long as it.
  defp hold_run(project_id, agent_id) do
    test = self()

    pid =
      spawn(fn ->
        RunLock.with_lock(
          project_id,
          fn ->
            send(test, :held)
            receive do: (:release -> :ok)
          end,
          agent_id: agent_id,
          label: "deploy (uat)"
        )

        send(test, :released)
      end)

    assert_receive :held
    pid
  end

  defp release(pid) do
    send(pid, :release)
    assert_receive :released
  end

  defp own_run(scope, agent_id) do
    {:ok, _run} =
      RunsRepository.start_run(scope, %{
        source: "spex",
        kind: :full,
        status: :running,
        requested_by: %{kind: "mcp_tool", tool: "start_analysis", agent_id: agent_id}
      })
  end

  defp refuse_until_later(scope, agent) do
    {:ok, agent} =
      AgentsRepository.update_agent(scope, agent, %{
        provider_refusal: "rate limited",
        provider_refused_at: DateTime.utc_now(),
        provider_retry_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    agent
  end

  describe "the wake" do
    test "is held while its provisioning step runs, and offered once it lands", ctx do
      run = hold_run(ctx.scope.active_project_id, ctx.agent.id)

      assert Waiting.reason(ctx.scope, ctx.agent, :wake) == {:provisioning, "deploy (uat)"}
      assert {:ok, :not_runnable} = Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)

      release(run)

      assert Waiting.reason(ctx.scope, ctx.agent, :wake) == nil

      refute match?(
               {:ok, :not_runnable},
               Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)
             )
    end

    test "is not held by a step another agent started", ctx do
      run = hold_run(ctx.scope.active_project_id, Ecto.UUID.generate())

      refute match?(
               {:ok, :not_runnable},
               Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)
             )

      release(run)
    end

    # Analysis and requirements are orthogonal: runs in flight hold the
    # turn-end message, never the work.
    test "is not held by its own analysis runs in flight", ctx do
      own_run(ctx.scope, ctx.agent.id)

      assert Waiting.reason(ctx.scope, ctx.agent, :turn_end) == :analysis_runs
      assert Waiting.reason(ctx.scope, ctx.agent, :wake) == nil

      refute match?(
               {:ok, :not_runnable},
               Work.request_turn_if_runnable(ctx.scope, ctx.agent, :test)
             )
    end
  end

  describe "the resume of a held task" do
    setup ctx do
      {:ok, held} =
        ctx.agent
        |> Agent.add_task(%{
          status: :active,
          requirement_name: "bdd_specs_passing",
          started_at: DateTime.add(DateTime.utc_now(), -300, :second)
        })
        |> Repo.update()

      %{agent: held}
    end

    # Instrument check: a held task with no turn open is resumed.
    test "resumes an agent waiting on nothing", ctx do
      :ok = Work.resume_held_tasks(ctx.scope, ctx.agent.working_copy_id)

      agent_id = ctx.agent.id
      assert_receive {:work_turn_requested, ^agent_id, _ref, _prompt}, 2_000
    end

    test "is held while its provisioning step runs", ctx do
      run = hold_run(ctx.scope.active_project_id, ctx.agent.id)

      :ok = Work.resume_held_tasks(ctx.scope, ctx.agent.working_copy_id)

      refute_receive {:work_turn_requested, _id, _ref, _prompt}, 500
      release(run)
    end

    test "is not held by its own analysis runs in flight", ctx do
      own_run(ctx.scope, ctx.agent.id)

      :ok = Work.resume_held_tasks(ctx.scope, ctx.agent.working_copy_id)

      agent_id = ctx.agent.id
      assert_receive {:work_turn_requested, ^agent_id, _ref, _prompt}, 2_000
    end
  end

  describe "the stop decision" do
    @impl_path "lib/example_context.ex"

    setup ctx do
      :ok =
        Environments.write_file(ctx.environment, @impl_path, "defmodule ExampleContext do\nend\n")

      Fixtures.deliver_manifest(ctx.scope)
      Fixtures.record_problem(ctx.scope, "credo", %{file_path: @impl_path})
      Fixtures.fresh_analysis_runs(ctx.scope, ["credo"])
      Fixtures.record_agent_edit(ctx.agent.id, @impl_path)
      :ok
    end

    test "says nothing while its provisioning step runs", ctx do
      run = hold_run(ctx.scope.active_project_id, ctx.agent.id)

      StopDecision.deliver(ctx.scope, ctx.agent, [])

      refute_receive {:agent_dispatch, _id, _ref, _message}, 500
      release(run)
    end

    test "says nothing while its own analysis runs are in flight", ctx do
      own_run(ctx.scope, ctx.agent.id)

      StopDecision.deliver(ctx.scope, ctx.agent, [])

      refute_receive {:agent_dispatch, _id, _ref, _message}, 500
    end

    test "says nothing before the provider's retry time", ctx do
      agent = refuse_until_later(ctx.scope, ctx.agent)

      StopDecision.deliver(ctx.scope, agent, [])

      refute_receive {:agent_dispatch, _id, _ref, _message}, 500
    end
  end

  # Main waiting on a person's answer is nudged into "still waiting" turns
  # otherwise. Only the nudge: its event wakes are messages, and coding or QA
  # questions block their task, not the agent.
  describe "a question pending on the user" do
    defp ask(scope, agent, holder \\ "user") do
      %QuestionRequest{}
      |> QuestionRequest.changeset(%{
        user_id: scope.user.id,
        agent_id: agent.id,
        title: "Which approach?",
        questions: [%{"question" => "Which?", "options" => [%{"label" => "A"}]}],
        holder: holder
      })
      |> Repo.insert!()
    end

    defp as_main(scope, agent) do
      {:ok, main} = AgentsRepository.update_agent(scope, agent, %{role: :main})
      main
    end

    test "holds main's turn-end nudge, not its wake", ctx do
      main = as_main(ctx.scope, ctx.agent)
      assert Waiting.reason(ctx.scope, main, :turn_end) == nil

      ask(ctx.scope, main)

      assert Waiting.reason(ctx.scope, main, :turn_end) == :question_pending
      assert Waiting.reason(ctx.scope, main, :wake) == nil
      assert Waiting.reason(ctx.scope, main, :resume) == nil
    end

    test "does not hold for a question main is answering for a teammate", ctx do
      main = as_main(ctx.scope, ctx.agent)
      ask(ctx.scope, main, "main_agent")

      assert Waiting.reason(ctx.scope, main, :turn_end) == nil
    end

    test "does not hold a coding agent, whose question blocks only its task", ctx do
      ask(ctx.scope, ctx.agent)

      assert Waiting.reason(ctx.scope, ctx.agent, :turn_end) == nil
    end
  end
end
