defmodule CodeMySpecSpex.QuestionRoutingHelpers do
  @moduledoc """
  Story 1052's shared premise: an agent with a question, a main agent between
  it and the user, and an answer that has to come back either way.

  Every criterion here is a claim about a *route* — who was asked, who
  answered, who saw it, and what the asker eventually got. So each leg is
  driven through the tool that leg really uses rather than through the records
  underneath: `ask_user_question` to raise one, `list_open_questions` and
  `answer_question` / `escalate_question` for the main agent's side,
  `check_answer` for the asker collecting, and `Notifications`' own answering
  path for the user.

  That last one matters more than it looks. `Fixtures.answer_question/3` calls
  `answer_question_request/2`, which is what the inbox form calls and the only
  thing that marks a request answered and releases whoever was waiting on it —
  a spex that set the status itself would pass against a field nothing in the
  product ever writes.
  """

  import ExUnit.Assertions
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.AnswerQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.EscalateQuestion
  alias CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions
  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.McpServers.Tasks.Tools.CheckAnswer
  alias CodeMySpecSpex.Fixtures

  @doc "The frame a tool call from this scope is made in."
  @spec frame(map()) :: Frame.t()
  def frame(context), do: %Frame{assigns: %{current_scope: context.scope}}

  @doc """
  An agent raises a question, through the tool an agent actually calls.

  Answers the question id. Asserted rather than pattern matched so a refusal
  names itself — a `nil` id three steps later reads as a routing failure when
  it was a malformed ask.
  """
  @spec ask(map(), String.t(), [String.t()]) :: String.t()
  def ask(context, question, options \\ ["Yes", "No"]) do
    params = %{
      questions: [
        %{
          "question" => question,
          "options" => Enum.map(options, &%{"label" => &1})
        }
      ]
    }

    {:reply, reply, _frame} = AskUserQuestion.execute(params, asking_frame(context))

    refute reply.isError,
           "the premise is a question that was raised, and this one was refused:\n" <>
             response_text(reply)

    Fixtures.question_id_from(response_text(reply))
  end

  @doc """
  The frame an *agent* asks from, as opposed to the main agent's own.

  `AskUserQuestion` reads `frame.assigns[:agent_id]`, which `Plugs.AgentScope`
  sets in production. Without it the request is written with a null `agent_id`,
  and `QuestionsRepository.list_open_questions/1` inner-joins `agents` — so the
  question is invisible to the main agent by construction and goes to the user
  by default, which is the behaviour this story exists to replace.

  A fresh agent per question, because these criteria are about routing between
  parties, and reusing one asker would let a scenario pass that only works when
  everything comes from the same place.
  """
  @spec asking_frame(map()) :: Frame.t()
  def asking_frame(context) do
    agent = Fixtures.running_agent(context.scope, role: "coding")

    %Frame{assigns: %{current_scope: context.scope, agent_id: agent.id}}
  end

  @doc "What the main agent sees waiting for it."
  @spec open_questions(map()) :: String.t()
  def open_questions(context),
    do: ListOpenQuestions |> call(%{}, context) |> response_text()

  @doc "The main agent answers from what the project records."
  @spec main_answers(map(), String.t(), String.t()) :: struct()
  def main_answers(context, question_id, answer) do
    call(AnswerQuestion, %{question_id: question_id, answer: answer, basis: "record"}, context)
  end

  @doc "The main agent hands one up, saying why it is the user's call."
  @spec main_escalates(map(), String.t(), String.t(), String.t() | nil) :: struct()
  def main_escalates(context, question_id, reason, as \\ nil) do
    params =
      %{question_id: question_id, reason: reason}
      |> then(&if as, do: Map.put(&1, :as, as), else: &1)

    call(EscalateQuestion, params, context)
  end

  @doc """
  The asking agent collects its answer, through the tool it really uses.

  Answers the reply text. `check_answer` is deliberately the *other* half of a
  two-step exchange — `ask_user_question` returns an id and this collects
  whenever the agent gets round to it — so "the answer came back" is a claim
  about this call and not about a row.
  """
  @spec collect(map(), String.t()) :: String.t()
  def collect(context, question_id),
    do: CheckAnswer |> call(%{question_id: question_id}, context) |> response_text()

  @doc "The user answers, the way the inbox form does."
  @spec user_answers(map(), String.t(), String.t()) :: :ok
  def user_answers(context, question_id, label),
    do: Fixtures.answer_question(context.scope, question_id, label)

  defp call(tool, params, context) do
    {:reply, reply, _frame} = tool.execute(params, frame(context))
    reply
  end
end
