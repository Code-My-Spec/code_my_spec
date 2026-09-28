defmodule CodeMySpecSpex.Story1012.Criterion3042Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 3042 — A Claude Code agent working the copy is told.

  Rule: an agent running under Claude Code learns about its working copy's
  problems on its next tool call.

  ## Why a persona is a criterion

  The other criteria on this story are about the *content* of the alert — how
  many, from which analyzer, how old, when to stay silent. This one and 3043 are
  about who the story is for, which is a different question and the one that
  decides where a change belongs.

  A Claude Code agent has exactly one way to be told anything between its own
  turns: the `PostToolUse` hook's `systemMessage`. It is not a process we
  supervise, it has no conversation we can write to, and nothing we own runs
  inside it. So the hook is not one delivery mechanism among several here — it
  is the whole of this story's reach, and an alert that does not ride it does
  not arrive.

  That is what makes the pair worth stating. An agent running inside our own
  BEAM is reached by something else entirely, and the temptation when the alert
  is reworded is to fix the path in front of you and leave the other one
  disagreeing. 3043 is the other half; story 1042 owns it.

  ## What this observes

  The hook's own response. Not a message on a conversation, not a log line —
  the JSON an agent's tool call gets back, which is the only thing a Claude
  Code agent ever sees.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The hook is the whole of this story's reach", criterion: 1116 do
    scenario "an analyzer run has landed with problems on the copy the agent is working" do
      given_ "an agent under Claude Code with an open working copy", context do
        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      given_ "an analyzer run for that copy has landed with problems", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "compiler",
          message: "** (SyntaxError) missing terminator: end",
          file_path: "lib/example_context.ex"
        })

        {:ok, context}
      end

      when_ "the agent makes its next tool call", context do
        told =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/post-tool-use", %{
            "session_id" => "a-claude-code-session",
            "tool_name" => "Read",
            "tool_input" => %{"file_path" => "lib/example_context.ex"}
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :told, told["systemMessage"])}
      end

      then_ "the result carries the alert", context do
        assert is_binary(context.told) and context.told != "",
               """
               A Claude Code agent was told nothing about a copy it is working
               that has problems recorded against it.

               There is no second chance to tell it. It is not a process we
               supervise and it has no conversation we can write to, so an alert
               that does not ride this response does not arrive at all — the
               agent carries on editing a tree it believes is clean.
               """

        {:ok, context}
      end

      then_ "and the alert names what landed", context do
        assert context.told =~ "compiler",
               """
               The alert reached the agent without saying which analyzer found
               something.

               "There are problems" is not actionable on its own: the agent has
               four sources it could be, and the one that matters decides
               whether it reaches for a compile error or a failing test. Got:
               #{context.told}
               """

        {:ok, context}
      end
    end
  end
end
