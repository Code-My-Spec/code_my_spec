defmodule CodeMySpecSpex.Story1042.Criterion3048Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3048 — Being told does not silence the other agent.

  Rule: Two agents in one working copy are told independently, whatever kind of
  agent each is.

  This has already been got wrong once, on the external side, and it was got
  wrong in a way worth remembering: the dedup key was
  `{working_copy_id, session_id}` while the comment above it read "two agents in
  one checkout are told independently". A Task-spawned subagent shares its
  parent's session, so the two collided and whichever spoke first silenced the
  other — story 890's criteria 2340 and 2341 false by construction. Issue
  `927c2b78`, fixed by putting the agent in the key.

  The internal agent arrives with a different identity again — an `agent_id` and
  no session at all — so this criterion exists to stop the same assumption being
  made a second time from the other direction. Dedup is per agent; it is not
  per checkout, and it is not per session.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Two agents in one working copy are told independently, whatever kind of agent each is" do
    scenario "Being told does not silence the other agent" do
      given_ "two agents working one copy, one under Alloy and one under Claude Code", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "compiler",
          message: "** (SyntaxError) missing terminator: end",
          file_path: "lib/example_context.ex"
        })

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "the one under Claude Code is told", context do
        told =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/post-tool-use", %{
            "session_id" => "an-external-session",
            "tool_name" => "Read"
          })
          |> Phoenix.ConnTest.json_response(200)

        assert is_binary(told["systemMessage"]),
               "the external agent was not told, so this scenario never reaches its subject"

        {:ok, context}
      end

      then_ "the other is still told on its own next tool call", context do
        assert {:ok, text} = Fixtures.run_script("return 1", agent_context(context))

        assert text =~ "compiler", """
        The Alloy agent heard nothing because another agent in the same checkout
        had already been told. That is the collision issue 927c2b78 fixed for
        two external agents, arriving again across the two kinds — and it is
        worse here, because the two do not even share an identity to collide on
        unless something threw one away.

        Got: #{inspect(text)}
        """

        {:ok, context}
      end
    end
  end
end
