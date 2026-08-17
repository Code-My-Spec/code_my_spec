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

  @earlier "Which approach do you want here?"
  @later "Should this ship behind a flag?"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A list is scoped to the session that asked" do
    scenario "an earlier session on this working copy has a question open" do
      given_ "an earlier session asked a question", context do
        context = start_session(context, "spex-2418-earlier")
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = AskUser.execute(%{message: @earlier}, frame)

        refute response.isError,
               "asking is the agent's own surface and has to work here. " <>
                 "Got: #{response_text(response)}"

        {:ok, context}
      end

      given_ "a later session starts and asks its own question", context do
        # Same user, same working copy, a new conversation. A question from
        # another *user* would be excluded by ownership alone and would prove
        # nothing about session scoping.
        #
        # The wait is not padding. `Sessions.external_id_for_harness/1` resolves
        # "newest wins" by `order_by desc: :inserted_at, limit: 1`, and
        # `sessions` carries `timestamps(type: :utc_datetime)` — second
        # granularity. Two sessions started inside one second tie, the limit
        # returns whichever row comes first, and both sessions' questions land
        # under one id. Without this the scenario cannot even establish its own
        # Given: there is no "earlier" session, only two indistinguishable ones.
        # Filed separately; the fix is usec timestamps, not a sleep in a spec.
        Process.sleep(1_100)

        context = start_session(context, "spex-2418-later")
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = AskUser.execute(%{message: @later}, frame)

        refute response.isError,
               "asking is the agent's own surface and has to work here. " <>
                 "Got: #{response_text(response)}"

        {:ok, context}
      end

      when_ "the later session's agent lists its questions", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListUserQuestions.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "its own question is listed", context do
        # The anchor: without it the refutation below passes against an empty
        # list, which is also what a broken tool returns.
        text = response_text(context.response)

        assert text =~ @later, "the current session's own question is missing. Got:\n#{text}"

        {:ok, Map.put(context, :text, text)}
      end

      then_ "the earlier session's question is not returned", context do
        refute context.text =~ @earlier,
               "a question belonging to another conversation must not appear " <>
                 "here — an agent that can see it can act on it, which is the " <>
                 "cross-working-copy bleed this scoping exists to prevent. " <>
                 "Got:\n#{context.text}"

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
