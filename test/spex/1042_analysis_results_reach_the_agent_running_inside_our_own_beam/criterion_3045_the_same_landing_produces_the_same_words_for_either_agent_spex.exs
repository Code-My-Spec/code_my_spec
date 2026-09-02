defmodule CodeMySpecSpex.Story1042.Criterion3045Spex do
  @moduledoc """
  Story 1042 — Analysis results reach the agent running inside our own BEAM.
  Criterion 3045 — The same landing produces the same words for either agent.

  Rule: The alert is the same one an external agent gets — same content, same
  silences.

  The point of the persona split was that delivery differs and the message does
  not. If the internal path grows its own wording, two agents looking at one
  broken tree describe it differently, and the next person to change the alert
  has to find both.

  So this drives **both surfaces against one landing**: the external agent's
  `PostToolUse` hook, and the internal agent's own tool call. The comparison is
  the assertion — not a fixed string, which would pin today's phrasing and fail
  the next time the alert is reworded for good reasons.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.AgentToolsHelpers

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The alert is the same one an external agent gets — same content, same silences" do
    scenario "The same landing produces the same words for either agent" do
      given_ "one analyzer run has landed with problems in a working copy", context do
        Fixtures.problem_fixture(context.scope, %{
          source: "compiler",
          message: "** (SyntaxError) missing terminator: end",
          file_path: "lib/example_context.ex"
        })

        {:ok, Map.put(context, :agent_id, running_agent(context))}
      end

      when_ "the alert is produced for an agent running under Claude Code", context do
        # The hook is the external agent's only way to be told, so it is the
        # honest surface for that half of the comparison.
        external =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, :post, "/api/hooks/post-tool-use", %{
            "session_id" => "an-external-session",
            "tool_name" => "Read"
          })
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :external, external["systemMessage"])}
      end

      when_ "and the alert is produced for an agent running under Alloy", context do
        {:ok,
         Map.put(context, :internal, Fixtures.run_script("return 1", agent_context(context)))}
      end

      then_ "both name the same analyzers, the same counts and the same age", context do
        assert is_binary(context.external),
               "the external agent got no alert, so there is nothing to compare against"

        assert {:ok, internal} = context.internal

        assert internal =~ context.external, """
        The two agents were told different things about one landing. Whatever
        the alert says, it is decided in one place and rendered for both — a
        second wording is a second thing to keep true.

        External: #{inspect(context.external)}
        Internal: #{inspect(internal)}
        """

        {:ok, context}
      end
    end
  end
end
