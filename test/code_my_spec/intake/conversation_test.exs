defmodule CodeMySpec.Intake.ConversationTest do
  @moduledoc """
  The conversation is a process, and that is the point.

  Everything that went wrong with guided intake was the socket holding state it
  could not keep: the turns lost on reload, the model call lost mid-flight, the
  re-ask that produced a different question every time because there was nothing
  to restore.

  These run the real `GenServer` — the rest of the suite runs it inline, because
  a process the sandbox does not own cannot see the transaction — with an
  explicit ownership grant, so the properties that only exist because it *is* a
  process are actually asserted.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Conversation
  alias Ecto.Adapters.SQL.Sandbox

  defmodule SlowShaper do
    @moduledoc false
    @behaviour CodeMySpec.Intake.Shaper

    @impl true
    def shape(_plan, turns) do
      # Long enough that a caller going away lands in the middle of it.
      Process.sleep(150)
      {:ask, "question after #{length(turns)} turn(s)"}
    end

    @impl true
    def conclude(_plan, _turns), do: {:ok, %{needs_sign_in: false, separate_copies: false}}
  end

  setup do
    # Shared mode, so the conversation and the task it owns can both see the
    # connection. Allowing them one at a time raced: the task is spawned by the
    # conversation, after any grant the test could make.
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    previous = Application.get_env(:code_my_spec, Intake, [])

    Application.put_env(:code_my_spec, Intake, Keyword.put(previous, :shaper, SlowShaper))
    Application.put_env(:code_my_spec, :intake_conversation_process, true)
    Application.put_env(:code_my_spec, :intake_shaping_async, true)

    on_exit(fn ->
      # The idle timeout is thirty minutes, so a conversation left running
      # outlives this test's sandbox and then crashes doing work for a database
      # that has gone. The suite stayed green and the log filled with ownership
      # errors from a test that had already passed.
      for {_, pid, _, _} <-
            DynamicSupervisor.which_children(CodeMySpec.Intake.ConversationSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(CodeMySpec.Intake.ConversationSupervisor, pid)

      # And the tasks they own. `async_nolink` deliberately does not link, so
      # terminating the conversation leaves its task running against a database
      # that is about to disappear.
      for pid <- Task.Supervisor.children(CodeMySpec.TaskSupervisor),
          do: Task.Supervisor.terminate_child(CodeMySpec.TaskSupervisor, pid)

      Application.put_env(:code_my_spec, Intake, previous)
      Application.put_env(:code_my_spec, :intake_conversation_process, false)
      Application.put_env(:code_my_spec, :intake_shaping_async, false)
    end)

    {:ok, plan} = Intake.start_plan(Intake.new_session_token())
    {:ok, plan: plan}
  end

  test "the call survives the caller going away", %{plan: plan} do
    :ok = Intake.subscribe(plan)

    conversation = Conversation.ensure_started(plan)

    # A caller that asks and then dies, which is a reload.
    caller = spawn(fn -> Conversation.said(plan, "a mahjong game with an ai coach") end)
    Process.sleep(20)
    Process.exit(caller, :kill)

    assert_receive {:shaped, shaped}, 5_000

    assert shaped.pending_question =~ "question after 0 turn(s)",
           "the answer was lost when the caller died. The whole reason this is a " <>
             "process is that a socket going away must not take the call with it."

    assert Process.alive?(conversation), "the conversation died with its caller"
  end

  test "two submissions do not race", %{plan: plan} do
    conversation = Conversation.ensure_started(plan)

    # A mailbox serialises these; two bare tasks would not.
    task_one = Task.async(fn -> Conversation.said(plan, "first") end)
    task_two = Task.async(fn -> Conversation.said(plan, "second") end)

    Task.await(task_one, 5_000)
    Task.await(task_two, 5_000)

    assert Process.alive?(conversation)
  end
end
