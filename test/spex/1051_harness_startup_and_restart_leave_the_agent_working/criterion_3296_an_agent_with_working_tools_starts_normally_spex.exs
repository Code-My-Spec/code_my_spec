defmodule CodeMySpecSpex.Story1051.Criterion3296Spex do
  @moduledoc """
  Story 1051 — Harness startup and restart leave the agent working.
  Criterion 3296 — An agent with working tools starts normally.

  Rule: An agent whose tools do not resolve fails loudly instead of running.

  The control for 3211, 3462 and 3212, and it earns its place. Every other
  criterion under this rule asks for a refusal or a raise, and the cheapest way
  to satisfy all three at once is to refuse more often — a stricter check that
  fires on a healthy machine passes them and makes the product unusable.

  So this one asserts that nothing is raised on the ordinary path, and it has
  to be a real start on a real machine rather than an assertion that no
  exception was thrown somewhere.

  ## What "takes turns" is asserted as

  Not by running one. `Alloy.Agent.Server` reaches a provider only when
  something chats to it, and chatting here would be a live model call on
  somebody's subscription from a criterion that is about startup. What is
  checked instead is everything that has to be true for a turn to be
  takeable — the agent is running, it is idle rather than stuck, and a tool
  call through its own surface answers — which is the whole of what the
  failing cases take away.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers, only: [running?: 1]
  import CodeMySpecSpex.HarnessLifecycleHelpers

  alias CmsHarnessTest.Machine
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent whose tools do not resolve fails loudly instead of running" do
    scenario "An agent with working tools starts normally" do
      given_ "an agent's tools all resolve at launch", context do
        context = given_a_staffed_checkout(context, "spex_3296")

        # A machine offering what a machine offers. Stated rather than left to
        # the default, because "the ordinary path" is the premise and a copy
        # that happened to report nothing would make this 3462.
        :ok =
          Fixtures.record_machine_tools(context.scope, ~w(browser_click browser_get_text))

        Fixtures.authored_story(context.scope, "a story the agent's tools can find")

        {:ok, context}
      end

      when_ "the agent is started", context do
        {:ok, Map.put(context, :agent_id, start_agent(context))}
      end

      then_ "it reaches a running state", context do
        assert running?(context.agent_id),
               "an agent with everything it needs did not come up"

        assert listing(context) =~ "Status: running",
               """
               The agent is running and the project's own listing does not say
               so. That is the surface an operator and the main agent both
               read, and a healthy agent that reads as anything else invites
               the restart that this story's note says made things worse.

               #{listing(context)}
               """

        {:ok, context}
      end

      then_ "and it takes turns and calls tools without anything being raised", context do
        assert {:ok, %{busy?: false, queued: 0}} = Machine.status(context.agent_id),
               "the agent is not in a state where a turn could be taken"

        assert {:ok, body} = tool_call(context.agent_id),
               """
               A correctly started agent cannot call a tool.

               Three criteria under this rule ask for a refusal or a raise, and
               the cheapest way to satisfy all of them is to fire more often.
               This is the one that says the ordinary path still works.
               """

        assert body =~ "a story the agent's tools can find",
               "the call answered something other than this project: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
