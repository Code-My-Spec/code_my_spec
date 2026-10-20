defmodule CodeMySpec.Agents.Tools.AnswerResponses do
  @moduledoc """
  What the main agent is told when it answers, and when it is told not to.

  Every refusal here is about something the main agent *could* have done, so
  each one says why the limit exists rather than only that it does. A refusal
  that reads as a missing feature gets worked around; one that reads as a rule
  gets respected, and the two are the same words apart.
  """

  @spec answered(map()) :: CodeMySpec.Tools.Tool.result()
  def answered(question) do
    {:ok,
     """
     Answered.

     Question: #{question.id}

     It has gone back to the agent that asked, the same way a person's answer
     would — it has no way to tell the two apart and does not need one. It is
     off your list.
     """}
  end

  @spec taken(map()) :: CodeMySpec.Tools.Tool.result()
  def taken(task) do
    {:ok, "Taken on: #{inspect(task)}"}
  end

  @spec error(term()) :: CodeMySpec.Tools.Tool.result()
  @doc """
  A permission settled, in the terms the decision actually has.

  Deliberately not worded as an answer. Allowing a `tap_out` stops an agent and
  denying it sends it back to work — neither is "it has gone back to the agent",
  and saying so would hide which of the two just happened.
  """
  @spec decided(String.t(), String.t()) :: CodeMySpec.Tools.Tool.result()
  def decided(id, "allow") do
    {:ok,
     """
     Allowed.

     Permission: #{id}

     The agent has its answer and is no longer waiting on one, so it is off your
     list and off the gate — a pending permission refuses a wake the same way an
     unanswered question does.
     """}
  end

  def decided(id, "deny") do
    {:ok,
     """
     Denied.

     Permission: #{id}

     The agent has its answer and is no longer waiting on one, so it is off your
     list and off the gate. It stays in the loop and can be woken again.
     """}
  end

  def error(:is_permission) do
    {:error,
     """
     That id is a permission, not a question — a `tap_out`, or an agent asking
     to call something. It cannot be answered with prose: pass
     `decision: "allow"` or `decision: "deny"` instead, and leave `answer` and
     `basis` out.

     Both kinds sit in `list_notifications` together because both stop an agent
     the same way, so reaching for the wrong verb is ordinary. The entry's
     `kind` says which it is.
     """}
  end

  def error({:unknown_decision, decision}) do
    {:error,
     """
     `#{decision}` is not a decision. A permission takes `allow` or `deny`.

     If you meant to answer a question rather than settle a permission, leave
     `decision` out and pass `answer` and `basis` instead.
     """}
  end

  def error({:not_that_role_s, role, tool}) do
    refuse("""
    Not done: `#{tool}` is deliberately not a #{role} tool, and using it on that \
    agent's behalf would be a way round the rule rather than a favour.

    The role not carrying it is a decision somebody made and wrote down. If you \
    think the decision is wrong, say so with `create_issue` — that changes it \
    for everybody and leaves a record. Doing it this once changes it silently \
    and only here.\
    """)
  end

  def error({:their_work, role}) do
    refuse("""
    Not taken on: the #{role} agent holding this is capable of it.

    Your wider scope is for what a role cannot do, not for what you would \
    rather not wait for. Taking capable work off an agent is defensible every \
    single time and ends with you doing all of it while three agents sit idle — \
    and work you did yourself has no QA counterpart, because QA reviews a coding \
    agent's work precisely because it is a coding agent's.

    If it is stuck rather than slow, `list_agent_work` says which, and \
    `restart_agent` is the remedy for stuck.\
    """)
  end

  def error(:missing_id) do
    refuse("`notification_id` is required — from `list_notifications`.")
  end

  def error(:not_found) do
    refuse("""
    No open question on this project has that id. It may already be answered — \
    `list_notifications` has what is still waiting.\
    """)
  end

  def error(:not_mine) do
    refuse(
      "No agent or conversation with that id exists here. `list_agent_work` has the agent ids."
    )
  end

  def error(:not_yours),
    do:
      refuse(
        "That question is not yours to answer: product answers the criteria questions " <>
          "routed to it, and the rest are main's or the user's."
      )

  def error(:with_user),
    do:
      refuse(
        "That question is the user's: it was routed straight to them, not through main, " <>
          "so only they can settle it."
      )

  def error(:not_recorded) do
    refuse("""
    Answer refused: with `basis: \"record\"`, the answer text must name a project
    record: an issue's title or first eight ID characters, a working copy's
    root or ID, a ready story without an epic's title, or the first eight ID
    characters of a resolved Question on the asker's story. The matching
    reference must be at least eight characters long and appear exactly in
    the answer text. No matching record was found in this answer.

    The question has been escalated to the user and remains unanswered; the
    asking agent is still waiting. You can retry with an answer that names
    the supporting record.
    """)
  end

  def error(reason), do: refuse("Could not do that: #{inspect(reason)}")

  defp refuse(text), do: {:error, text}
end
