defmodule CodeMySpecSpex.Story1017.Criterion2418Spex do
  @moduledoc """
  Story 896 — Agent sees the questions it has open
  Criterion 2418 — One session's questions stay out of another's list.

  The rule:

  > An agent can list the questions it asked in this session.

  The boundary half of 2417. "The questions it asked" is the whole constraint;
  without this, an implementation that lists every question the *user* has open
  satisfies 2417 completely.

  ## Why session and not user

  Decided in the Three Amigos session, against two alternatives. Listing
  everything open for the user would let an agent in one worktree see — and,
  more to the point, act on — a question another worktree asked, which is the
  same cross-working-copy bleed that made the stop hook block on devops spex
  belonging to somewhere else. Scoping by harness rather than session was the
  near miss: it survives a restart, which is when an agent is most likely to
  have forgotten what it asked.

  Session was chosen knowing the cost: a restarted agent gets a new session id
  and stops seeing its earlier questions. They remain in the user's inbox, which
  is where a human answers them anyway.

  ## What the scenario has to establish

  Two sessions on the same user, so the filter cannot pass by accident on user
  identity. A question asked from a *different* user would be excluded by
  ownership alone, and the spec would prove nothing about sessions.

  ## Surface

  The MCP tool, with two sessions created through the real `session-start` hook.
  The stray question is asked while the second session is the harness's current
  one, so it is stamped with that session's id; the listing agent's scope points
  at the first.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.AskUser
  alias CodeMySpec.McpServers.Tasks.Tools.ListUserQuestions

  @mine "Which approach do you want here?"
  @theirs "Should the other worktree ship behind a flag?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A list is scoped to the session that asked" do
    scenario "another session on the same user has a question open" do
      given_ "a session exists and asks a question", context do
        context = start_session(context, "spex-2418-mine")
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = AskUser.execute(%{message: @mine}, frame)

        refute response.isError,
               "asking is the agent's own surface and has to work here. " <>
                 "Got: #{response_text(response)}"

        {:ok, Map.put(context, :mine_session_id, context.session_id)}
      end

      given_ "a second session starts and asks a different question", context do
        # Same user, same working copy, different conversation. A question from
        # another *user* would be excluded by ownership alone and would prove
        # nothing about session scoping.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        context = start_session(context, "spex-2418-theirs")

        {:reply, response, _frame} = AskUser.execute(%{message: @theirs}, frame)

        refute response.isError,
               "asking is the agent's own surface and has to work here. " <>
                 "Got: #{response_text(response)}"

        {:ok, context}
      end

      when_ "the first session's agent lists its questions", context do
        scope = Map.put(context.scope, :active_session_external_id, context.mine_session_id)
        frame = %Frame{assigns: %{current_scope: scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the other session's question is not returned", context do
        text = response_text(context.response)

        refute text =~ @theirs,
               "a question belonging to another conversation must not appear " <>
                 "here — an agent that can see it can act on it, which is the " <>
                 "cross-working-copy bleed this scoping exists to prevent. " <>
                 "Got:\n#{text}"

        {:ok, context}
      end
    end
  end

  defp start_session(context, prefix) do
    session_id = "#{prefix}-#{System.unique_integer([:positive])}"

    Phoenix.ConnTest.build_conn()
    |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> post(~p"/api/hooks/session-start", %{"session_id" => session_id})
    |> Phoenix.ConnTest.json_response(200)

    Map.put(context, :session_id, session_id)
  end
end
