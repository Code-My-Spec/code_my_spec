defmodule CodeMySpecSpex.Story985.Criterion3036Spex do
  @moduledoc """
  Story 985 — I can see what the orchestrator did to my agent, not just what my
  agent did.
  Criterion 3036 — An agent reading its own transcript can act on what it finds.

  Rule: An action says what happened, how much of it there is, and which tool
  answers for the rest.

  The half of that rule that decides its shape. I proposed a link to the page
  that already lists the detail; John's answer was "instructions on what tool to
  use to get the info (list problems in this case)", and that is the better
  answer for a reason worth writing down: half the readers of an agent's
  transcript are agents, and an agent cannot follow a link.

  ## Surface, and what this can honestly assert

  There is no tool today with which an agent reads its own conversation — it
  reaches its history through Alloy, inside the harness, which a spex does not
  drive. So this asserts the property that makes the criterion true rather than
  staging the reader: the action carries a name a caller can *use*, and carries
  no URL that only a person could follow.

  That property is about the content of the action and is the same wherever it
  is read, which is why it can be checked here without pretending to be an
  agent. If a read-my-transcript tool arrives later, this is the assertion it
  should be re-pointed at.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.SharedGivens
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "An action says what happened, how much of it there is, and which tool answers for the rest" do
    scenario "An agent reading its own transcript can act on what it finds" do
      given_ :synced_context_component
      given_ :context_spec_task_started

      given_ "an agent reading back the conversation it is in", context do
        {:ok, given_a_main_checkout(context, "the main checkout")}
      end

      when_ "it reaches an orchestrator action that summarises something", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Phoenix.ConnTest.dispatch(CodeMySpecLocalWeb.Endpoint, :post, "/api/hooks/stop", %{
          "session_id" => context.session_id
        })
        |> then(fn conn ->
          # A `when_` whose own action quietly did nothing produces a `then_`
          # that fails for the wrong reason, and reads as the feature being
          # missing rather than the step never having run.
          assert conn.status == 200,
                 "the stop hook did not answer: #{conn.status}"
        end)

        {:ok, _live, html} = live(context.conn, main_conversation_path(context))

        {:ok, Map.put(context, :transcript, html)}
      end

      then_ "what it finds is the name of a tool it can call", context do
        assert context.transcript =~ "list_problems",
               "the orchestrator's action reaches the agent with no way to act on it. " <>
                 "A summary an agent cannot follow up is a summary it has to take on " <>
                 "trust, which is the opposite of what a count is for."

        {:ok, context}
      end

      then_ "and not a link, which it cannot follow", context do
        refute context.transcript =~ ~r{href="[^"]*problems},
               "the action points at a page. A person clicks it and an agent cannot, " <>
                 "and both are reading this transcript."

        {:ok, context}
      end
    end
  end
end
