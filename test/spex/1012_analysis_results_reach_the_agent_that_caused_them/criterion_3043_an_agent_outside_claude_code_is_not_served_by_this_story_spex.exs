defmodule CodeMySpecSpex.Story1012.Criterion3043Spex do
  @moduledoc """
  Story 1012 — Analysis results reach the agent that caused them.
  Criterion 3043 — An agent outside Claude Code is not served by this story.

  Rule: an agent running inside our own BEAM is reached by something else, and
  that something else is story 1042.

  ## A scope statement, asserted rather than assumed

  3042 says the `PostToolUse` hook is the whole of this story's reach. The hook
  is HTTP, and an Alloy agent never makes one: it calls its tools in-process,
  so there is no request for a `systemMessage` to ride back on. Nothing about
  this story's mechanism reaches it.

  Left as a remark in a moduledoc, that is the kind of claim that quietly stops
  being true. The failure it guards against is not a missing alert but a
  *duplicated* one: someone reworking delivery here notices the internal agent
  is not covered, adds a second path, and now one landing has two renderings
  that drift. 3045 on story 1042 exists to catch the drift; this exists to keep
  the second path from being added at all.

  ## What it observes

  That the internal agent is told **without this story's mechanism having
  run**. No hook is posted in this scenario at all — the alert arrives on the
  tool result, which is `CmsHarness`'s path and story 1042's subject.

  Asserting the absence directly ("post no hook, see no alert") would assert
  nothing: a hook nobody posts produces no response to inspect either way. So
  the claim is made positively, on the surface that does the reaching, and the
  boundary is what the two criteria say together.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentToolsHelpers

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The internal agent is reached by story 1042, not by this one" do
    scenario "an analyzer run has landed with problems and no hook is ever posted" do
      given_ "an agent running inside our own BEAM with an open working copy", context do
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
        # In-process, which is the point. No `PostToolUse` request is made
        # anywhere in this scenario — an Alloy agent has no hook to fire.
        {:ok, Map.put(context, :told, Fixtures.run_script("return 1", agent_context(context)))}
      end

      then_ "it is told anyway, by a mechanism this story does not own", context do
        assert {:ok, told} = context.told

        assert told =~ "compiler",
               """
               The internal agent was not told, and this story's hook is not
               going to tell it — it never fires for an agent that calls its
               tools in-process.

               If this is failing, the gap is in story 1042 (`CmsHarness`'s tool
               result path), not here. Fixing it here by adding a second
               delivery is the thing both criteria exist to prevent: one landing
               with two renderings, drifting apart, and 3045 failing next.

               Got: #{inspect(told)}
               """

        {:ok, context}
      end
    end
  end
end
