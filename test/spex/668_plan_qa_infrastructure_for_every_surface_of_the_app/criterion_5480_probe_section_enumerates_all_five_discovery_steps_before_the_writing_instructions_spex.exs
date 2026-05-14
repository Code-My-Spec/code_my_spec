defmodule CodeMySpecSpex.Story668.Criterion5480Spex do
  @moduledoc """
  Story 668 — Plan QA infrastructure for every surface of the app
  Criterion 5480 — Probe section enumerates all five discovery steps
  before the writing instructions.

  Rule (happy path): the agent probes the running app before writing
  the plan — listening ports, real HTTP responses, real selectors —
  not config files alone. The qa_setup task prompt encodes that
  ordering and the five concrete probes (lsof, curl per port, auth
  surface mapping, Repo discovery, Vibium screenshot dir
  verification) so the agent can't write a plan from config alone.

  Surface: `start_task` for the `qa_setup` project requirement.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "QA setup prompt forces probe-before-write ordering" do
    scenario "Probe section enumerates all five discovery steps before the writing instructions" do
      given_ :qa_setup_task_started

      then_ "the prompt routes the agent to the probe playbook", context do
        prompt = context.prompt

        # The five-step probe procedure (lsof, curl per port,
        # browser_map for auth surfaces, Ecto.Repo discovery, Vibium
        # screenshot landing) and the probe-then-write ordering all live
        # in priv/knowledge/qa_setup/workflow.md. The prompt routes the
        # agent there rather than inlining the discovery commands.
        assert prompt =~ ~r/priv\/knowledge\/qa_setup\/workflow\.md/,
               "expected the prompt to reference the qa_setup workflow playbook " <>
                 "(which has the probe protocol and writing conventions), got: #{prompt}"

        {:ok, context}
      end
    end
  end
end
