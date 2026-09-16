defmodule CodeMySpec.McpServers.MainAgent.AnswerMapper do
  @moduledoc """
  What the main agent is told when it answers, and when it is told not to.

  Every refusal here is about something the main agent *could* have done, so
  each one says why the limit exists rather than only that it does. A refusal
  that reads as a missing feature gets worked around; one that reads as a rule
  gets respected, and the two are the same words apart.
  """

  alias Anubis.Server.Response

  @spec answered(map()) :: Response.t()
  def answered(question) do
    Response.tool()
    |> Response.text("""
    Answered.

    Question: #{question.id}

    It has gone back to the agent that asked, the same way a person's answer
    would — it has no way to tell the two apart and does not need one. It is
    off your list.
    """)
  end

  @spec taken(map()) :: Response.t()
  def taken(task) do
    Response.tool()
    |> Response.text("Taken on: #{inspect(task)}")
  end

  @spec error(term()) :: Response.t()
  @doc """
  A permission settled, in the terms the decision actually has.

  Deliberately not worded as an answer. Allowing a `tap_out` stops an agent and
  denying it sends it back to work — neither is "it has gone back to the agent",
  and saying so would hide which of the two just happened.
  """
  @spec decided(String.t(), String.t()) :: Response.t()
  def decided(id, "allow") do
    Response.tool()
    |> Response.text("""
    Allowed.

    Permission: #{id}

    The agent has its answer and is no longer waiting on one, so it is off your
    list and off the gate — a pending permission refuses a wake the same way an
    unanswered question does.
    """)
  end

  def decided(id, "deny") do
    Response.tool()
    |> Response.text("""
    Denied.

    Permission: #{id}

    The agent has its answer and is no longer waiting on one, so it is off your
    list and off the gate. It stays in the loop and can be woken again.
    """)
  end

  def error({:unknown_decision, decision}) do
    Response.tool()
    |> Response.error("""
    `#{decision}` is not a decision. A permission takes `allow` or `deny`.

    If you meant to answer a question rather than settle a permission, leave
    `decision` out and pass `answer` and `basis` instead.
    """)
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

  def error(:not_found) do
    refuse("""
    No open question on this project has that id. It may already be answered — \
    `list_notifications` has what is still waiting.\
    """)
  end

  def error(:not_mine) do
    refuse("That is not one of your agents. `list_agent_work` has the ones that are.")
  end

  def error(reason), do: refuse("Could not do that: #{inspect(reason)}")

  defp refuse(text), do: Response.tool() |> Response.error(text)
end
