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
  # An agent waits on questions and on permission requests alike
  # (`Notifications.awaiting_answer?/1`). A listing of only the first half cannot
  # explain the wait: an agent held off the graph by a pending `tap_out` appears
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

  @behaviour CodeMySpec.McpServers.ScriptResult

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.McpServers.MainAgent.MainAgentMapper
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case questions(frame) do
      {:ok, scope, questions} ->
        {:reply, MainAgentMapper.listing(questions, mine(scope, frame)), frame}

      {:error, reason} ->
        {:reply, MainAgentMapper.error(reason), frame}
    end
  end

  @impl CodeMySpec.McpServers.ScriptResult
  def script_result(_params, frame) do
    with {:ok, _scope, questions} <- questions(frame) do
      {:ok, Enum.map(questions, &row/1)}
    end
  end

  defp questions(frame) do
    case Validators.validate_local_scope(frame) do
      {:ok, scope} -> {:ok, scope, MainAgent.list_open_questions(scope)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row(question) do
    %{
      "id" => question.id,
      "kind" => to_string(question.kind),
      "title" => question.title,
      "holder" => question.holder,
      "story_id" => question.story_id,
      "agent_id" => question.agent_id,
      "agent_role" => question.agent_role && to_string(question.agent_role),
      "working_copy_id" => question.working_copy_id,
      "working_copy_label" => question.working_copy_label
    }
  end

  # Product's own are the criteria questions routed to it (8c91d5bc).
  defp mine(scope, %{assigns: %{agent_id: id}}) when is_binary(id) do
    case CodeMySpec.Agents.fetch_agent(scope, id) do
      {:ok, %{role: :product}} -> "product_agent"
      _ -> "main_agent"
    end
  end

  defp mine(_scope, _frame), do: "main_agent"
end
