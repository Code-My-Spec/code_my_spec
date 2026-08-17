defmodule CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions do
  @moduledoc """
  Every question you have asked the user in this session, oldest first.

  The agent's own view of what it is waiting on. `ask_user` returns an id and
  `check_answer` collects one reply, which works while the agent remembers what
  it asked — and across a compaction it does not. Without a listing the only
  record is in the user's inbox, where the agent cannot see it, so a question
  raised before the context was summarised is simply lost: never collected,
  never re-asked, and the work that prompted it quietly proceeds without the
  answer.

  ## Scope

  This session, resolved from the working copy — the agent's scope carries a
  harness and never a session id, the same asymmetry `ask_user` works around.

  Session rather than harness or user, decided in story 896's Three Amigos.
  Listing everything open for the *user* would let an agent in one worktree see,
  and act on, a question another worktree asked — the cross-working-copy bleed
  that had the stop hook blocking on devops spex belonging somewhere else.
  Harness scope was the near miss: it survives a restart, which is exactly when
  an agent has most likely forgotten. The cost of choosing session is that a
  restarted agent stops seeing its earlier questions; they remain in the user's
  inbox, which is where a person answers them anyway.

  ## Open means unanswered, and nothing else

  There is no expiry. `expired` was a status with two readers and no writer, and
  896 chose to delete it rather than build the sweeper that would justify it: a
  question the user never answered is still a question, and one that vanishes on
  a timer is a decision they never made disappearing from the one place they
  would have seen it.

  Answered questions are **not** listed. A first draft included them with their
  replies, on the reasoning that "you asked this, here is what came back" is
  cheap context recovery. It is, and it belongs to `check_answer`, which exists
  to hand back exactly that. Listing them here contradicts both the criterion
  and the name: this answers "what am I still waiting on", and an answer that
  has landed is not something to wait on. A list that keeps returning answered
  questions reproduces `e39b4eba`'s harm — the agent chasing a reply it already
  has — at a new surface.

  Named `list_user_questions` because `list_questions` is taken by Three Amigos
  red cards, and an agent sees both in one tool list. `user` is what separates a
  question asked *of the user* from one parked against a story.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Notifications
  alias CodeMySpec.Sessions

  schema do
  end

  @impl true
  def execute(_params, frame) do
    scope = frame.assigns[:current_scope]

    case Sessions.external_id_for_harness(harness_id(scope)) do
      nil ->
        {:reply, Response.tool() |> Response.text(no_session()), frame}

      external_id ->
        questions =
          external_id
          |> Notifications.list_question_requests_for_session()
          |> Enum.filter(&(&1.status == "pending"))

        {:reply, Response.tool() |> Response.text(render(questions)), frame}
    end
  end

  defp render([]) do
    """
    Nothing is waiting on the user — you have no open questions in this session.

    If you need a decision to go further, `ask_user` raises one.
    """
  end

  defp render(questions) do
    header =
      case length(questions) do
        1 -> "1 open question, waiting on the user:"
        n -> "#{n} open questions, waiting on the user:"
      end

    body = Enum.map_join(questions, "\n", &"  - #{text(&1)}\n    id: #{&1.id}")

    header <>
      "\n" <>
      body <>
      "\n\nCall `check_answer` with an id to collect a reply once it lands. " <>
      "Do not re-ask any of these — that queues a duplicate for the user."
  end

  # The question as the user saw it. `questions` is the tool's array verbatim,
  # and a free-form `ask_user` puts exactly one entry in it.
  defp text(%{questions: [%{"question" => q} | _]}) when is_binary(q), do: q
  defp text(%{title: title}) when is_binary(title), do: title
  defp text(_request), do: "(no question text)"


  defp no_session do
    """
    No session is registered for this working copy, so there are no questions to
    list. A question is tied to the conversation it was asked in, and that link
    is made from the session running here.
    """
  end

  defp harness_id(%{active_harness_id: id}) when is_binary(id), do: id
  defp harness_id(_scope), do: nil
end
