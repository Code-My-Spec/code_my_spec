defmodule CodeMySpec.MainAgent.TheCadenceDeliversATurnTest do
  @moduledoc """
  The tick has to reach the agent, not just move `last_check`.

  `2c34da87`, reported by a main agent measuring its own cadence: the timer
  fired and no turn arrived. `check_in/1` returned the report to its caller, and
  from the timer that caller was the `Cadence` process, which dropped it.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  import Ecto.Query

  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.MainAgent.Cadence
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    previous = Application.get_env(:code_my_spec, :agent_transport)
    Application.put_env(:code_my_spec, :agent_transport, RecordingAgentTransport)
    on_exit(fn -> Application.put_env(:code_my_spec, :agent_transport, previous) end)
    RecordingAgentTransport.listen()
    :ok
  end

  defp main_agent(scope) do
    # `Agents.main_agent/1` resolves through `WorkingCopies.main/1`; the fixture's
    # copy is not flagged, so nothing would be found to deliver to.
    {1, _} =
      Repo.update_all(
        from(w in WorkingCopy, where: w.id == ^scope.active_working_copy_id),
        set: [main: true]
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        role: "main",
        status: :running,
        continuous: false,
        provider: "anthropic",
        engine: :alloy,
        working_copy: "/tmp/cadence-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  # a31f1cd6 step 4b, John: "hold them". A non-continuous agent is woken only by
  # a person and its own replies, so the tick no longer pushes it the digest; a
  # continuous main is offered a turn by `Work.consider_project/2` instead.
  test "a tick holds the digest from a non-continuous main" do
    scope = full_scope_fixture()
    _main = main_agent(scope)

    assert Agents.main_agent(scope), "main_agent/1 cannot find the agent"

    {:ok, pid} = Cadence.start_link(scope)
    send(pid, :check_in)

    refute_receive {:agent_message, _id, _text}, 1_000
  end

  test "a stood-down project's tick delivers nothing" do
    scope = full_scope_fixture()
    _main = main_agent(scope)
    :ok = Cadence.stand_down(scope)

    {:ok, pid} = Cadence.start_link(scope)
    send(pid, :check_in)

    refute_receive {:agent_message, _id, _text}, 1_000
  end

  defp coding_agent(scope) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        role: "coding",
        status: :running,
        continuous: false,
        provider: "anthropic",
        engine: :alloy,
        working_copy: "/tmp/cadence-coding-#{System.unique_integer([:positive])}",
        working_copy_id: scope.active_working_copy_id
      })

    agent
  end

  defp ask(scope, agent_id) do
    {:ok, _request} =
      Notifications.create_agent_question_request(
        scope,
        agent_id,
        %{"title" => "Blocked", "questions" => [%{"question" => "Which way?", "options" => []}]},
        nil
      )
  end

  # Step 4b: held for a non-continuous main as well; it collects them from
  # `list_notifications` when a person brings it back.
  describe "a blocker raised by another agent, to a non-continuous main" do
    test "a question does not wake it" do
      scope = full_scope_fixture()
      _main = main_agent(scope)
      coder = coding_agent(scope)
      {:ok, _pid} = Cadence.start_link(scope)

      ask(scope, coder.id)

      refute_receive {:agent_message, _id, _text}, 1_000
    end

    test "a tap-out does not wake it" do
      scope = full_scope_fixture()
      _main = main_agent(scope)
      coder = coding_agent(scope)
      {:ok, _pid} = Cadence.start_link(scope)

      {:ok, _request} = Notifications.request_agent_tap_out(scope, coder.id, nil, "stuck")

      refute_receive {:agent_message, _id, _text}, 1_000
    end
  end

  test "main's own question does not wake it" do
    scope = full_scope_fixture()
    main = main_agent(scope)
    {:ok, _pid} = Cadence.start_link(scope)

    ask(scope, main.id)

    refute_receive {:agent_message, _id, _text}, 1_000
  end
end
