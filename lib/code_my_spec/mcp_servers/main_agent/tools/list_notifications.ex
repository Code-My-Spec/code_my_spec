defmodule CodeMySpec.McpServers.MainAgent.Tools.ListNotifications do
  @moduledoc """
  Everything the agents on this project are waiting on, in one place.

  Questions and permissions together — a `tap_out` stops an agent exactly as an
  unanswered question does. Grouped by who holds each one: yours to answer, or
  already sent up and waiting on the user. `kind` says whether it takes an
  answer or a decision. Settle any of them with `answer_notification`.
  """

  # Why both kinds, and why one listing
  #
  # `Notifications.awaiting_answer?/1` — the predicate `StopDecision.wake/2`
  # consults before it will wake anything — is `pending_question? or
  # pending_permission?`. A listing that unions only the first half cannot
  # explain the gate: an agent held off the graph by a pending `tap_out` appears
  # in it as nothing at all. `880c7713` spent seven hours unreachable that way
  # while every other surface reported it running, continuous and idle with 17
  # actionable requirements (`8cb3f626`).
  #
  # So the rule is that this listing mirrors that predicate. If the two ever
  # disagree again, the listing is the one that is wrong.
  #
  # Replaces `list_open_questions`, which named only half of what it returned.
  #
  # Why this is not one of the two listings that already exist
  #
  # `list_user_questions` answers "what have *I* asked", scoped to the calling
  # session and deliberately so — session scope is what stops an agent in one
  # worktree acting on a question another worktree raised. This needs the
  # opposite: everything asked *by* the agents of one project, whoever asked it.
  #
  # `list_agents` answers which agents exist. Hanging questions off it would
  # make one listing answer two questions and charge every caller that wants one
  # for the other.
  #
  # Comments rather than moduledoc: `Anubis.Server.Component` advertises the
  # moduledoc as the tool's description and `SpineTest` holds the whole spine
  # under 20 KB.

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.MainAgent
  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} ->
        {:reply, MainAgentMapper.listing(MainAgent.list_open_questions(scope)), frame}

      {:error, reason} ->
        {:reply, MainAgentMapper.error(reason), frame}
    end
  end
end
