defmodule CodeMySpec.Intake.InterviewTest.NilInterviewer do
  @moduledoc """
  Stands in for a real interviewer that answered a tool call with no
  `question` field at all — the shape `Interviewer.Llm` now refuses to pass
  on (918d20e7), but `Interviewer` is a behaviour, and `Interview.ask_next/2`
  should not depend on every implementation getting that validation right.
  """
  @behaviour CodeMySpec.Intake.Interviewer

  @impl true
  def ask(_plan, _turns), do: {:ok, nil}

  @impl true
  def derive(_plan, _turns), do: {:ok, []}
end

defmodule CodeMySpec.Intake.InterviewTest do
  @moduledoc """
  The post-signup interview (`/build/workspace`) writes into its own
  `intake_interview_turns` table, entirely separate from `conversations` —
  the model `agent-conversation` reads. Before this, a question asked or an
  answer given here never reached that page at all: `Intake.convert/2`'s own
  copy of the shaping conversation only runs once, at signup, and the
  interview happens strictly after it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Conversations
  alias CodeMySpec.Conversations.Message
  alias CodeMySpec.Intake
  alias CodeMySpec.Intake.Interview

  defp converted_plan do
    scope = user_scope_fixture()
    token = Intake.new_session_token()
    {:ok, plan} = Intake.start_plan(token)
    {:ok, plan} = Intake.describe(plan, "a booking tool for hair salons")
    {:ok, plan} = Intake.answer(plan, %{needs_sign_in: true, separate_copies: true})
    {:ok, plan} = Intake.generate_plan(plan)
    {:ok, plan} = Intake.confirm_names(plan, %{account_name: "Acme", project_name: "Salon"})
    {:ok, plan} = Intake.convert(plan, scope)
    plan
  end

  defp conversation_texts(plan) do
    {:ok, conversation} =
      Conversations.find_or_create_session_conversation(
        plan.account_id,
        plan.project_id,
        "intake:#{plan.id}"
      )

    conversation |> Conversations.list_messages() |> Enum.map(&Message.text/1)
  end

  test "the first question is mirrored into the conversation as it is asked" do
    plan = converted_plan()

    assert {:ok, turn} = Interview.current_turn(plan)

    assert turn.question in conversation_texts(plan),
           "the interview asked something the agent-conversation page will never show"
  end

  test "an answer is mirrored into the conversation as it is given" do
    plan = converted_plan()
    {:ok, turn} = Interview.current_turn(plan)

    assert {:ok, _turn} = Interview.answer(turn, "Salon owners, checking their week")

    assert "Salon owners, checking their week" in conversation_texts(plan),
           "the visitor's own answer never reached the agent's own conversation"
  end

  test "asking and answering land in the same conversation the shaping half already opened" do
    plan = converted_plan()
    {:ok, turn} = Interview.current_turn(plan)
    {:ok, _turn} = Interview.answer(turn, "Salon owners, checking their week")

    texts = conversation_texts(plan)

    assert "a booking tool for hair salons" in texts,
           "the interview's own conversation is a second one, not the same thread " <>
             "Intake.convert/2 already opened"
  end

  test "an interviewer answering with no question is treated as the interview being unavailable, not a crash" do
    previous_intake = Application.get_env(:code_my_spec, Intake, [])

    Application.put_env(
      :code_my_spec,
      CodeMySpec.Intake,
      Keyword.put(previous_intake, :interviewer, CodeMySpec.Intake.InterviewTest.NilInterviewer)
    )

    on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Intake, previous_intake) end)

    plan = converted_plan()

    assert {:error, :interview_unavailable} = Interview.current_turn(plan),
           "a nil question reached something other than the existing " <>
             "'interview isn't available right now' branch"
  end
end
