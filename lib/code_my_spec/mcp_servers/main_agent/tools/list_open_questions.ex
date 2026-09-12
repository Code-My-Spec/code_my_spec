defmodule CodeMySpec.McpServers.MainAgent.Tools.ListOpenQuestions do
  @moduledoc """
  Everything the agents on this project are waiting on, in one place.

  Grouped by who holds each question — yours to answer, or already sent up and
  waiting on the user. An answered question is gone from here.
  """

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
