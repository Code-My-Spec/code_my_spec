defmodule CodeMySpecSpex.Story1070.Criterion3534Spex do
  @moduledoc """
  Story 1070 — An agent does the right thing with the tools it has.
  Criterion 3534 — A tool that is missing from the agent's surface is filed as
  a framework issue.

  Rule: An agent files a framework issue when the tooling is what is broken.

  Where 3543's report has to land. Saying it in a reply reaches nobody — the
  conversation ends with the turn — so the only durable form is an issue, and
  the only useful scope is `framework`, because the thing that is broken is the
  harness rather than the application being built.

  Filing it against the story the agent happened to be working is the failure
  this rules out, and it is the tempting one: the story is in front of the
  agent, `story_id` is right there, and the issue then blocks a story that has
  nothing to do with the fault while the fault goes unlisted in the framework
  backlog. Every one of the six prior instances recorded in
  `CmsHarness.Agents.Engine.tools/1` was found by a person hitting it again
  rather than by reading a list.

  The premise is a tool named to the agent that does not exist anywhere. That
  is exactly the shape of the incident (`23f5544e`): the stop menu named
  `list_tasks` to a surface that did not carry it. Naming one here reproduces
  the premise without needing a real absence in the tree to still be there.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentEvalHelpers
  import CodeMySpecSpex.SharedGivens

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :eval
  # `CodeMySpecSpex.Case` sets three minutes, which is right for a spex that
  # drives a surface and far too short for one that drives ten agents.
  @moduletag timeout: CodeMySpecSpex.AgentEvalHelpers.eval_timeout()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "An agent files a framework issue when the tooling is what is broken" do
    scenario "A tool that is missing from the agent's surface is filed as a framework issue" do
      given_ :synced_context_in_satisfied_project

      given_ "a checkout on the harness, reporting what its agents do", context do
        {:ok, given_a_harnessed_checkout(context, "eval_3534")}
      end

      when_ "the agent is told to use a tool nothing carries", context do
        measured =
          measure("A tool that is missing from the agent's surface is filed as a framework issue",
            fn _run ->
              told =
                "Before you start, call `list_my_open_tasks` to see what you are " <>
                  "already holding. It is on your surface."

              observe(context, [role: "coding", wake: false, say: told], fn _agent ->
                filed_at?(context, "framework")
              end)
            end)

        {:ok, Map.put(context, :measured, measured)}
      end

      then_ "the fault is in the framework backlog rather than on a story", context do
        assert_rate(context.measured, 0.8)

        refute filed_at?(context, "app"),
               """
               The tooling fault was filed against the application.

               A framework fault on a story blocks work that has nothing to do
               with it and leaves the framework backlog empty — so the thing
               that is broken goes unlisted while something that is not broken
               is marked as blocked.

               #{issues_filed(context, %{scope: "app"})}
               """

        {:ok, context}
      end
    end
  end
end
