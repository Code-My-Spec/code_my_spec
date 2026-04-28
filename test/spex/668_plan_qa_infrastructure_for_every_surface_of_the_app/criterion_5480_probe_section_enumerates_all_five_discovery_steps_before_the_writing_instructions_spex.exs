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

      then_ "the prompt has a Probe section with all five discovery steps", context do
        prompt = context.prompt

        assert prompt =~ ~r/##\s+Probe/i,
               "expected Probe H2 in prompt, got: #{prompt}"

        assert prompt =~ "lsof",
               "expected step 1 (lsof) in prompt, got: #{prompt}"

        assert prompt =~ ".well-known/oauth-authorization-server",
               "expected step 2 (curl per port + .well-known) in prompt, got: #{prompt}"

        assert prompt =~ ~r/browser_map|auth surface/i,
               "expected step 3 (auth surface mapping) in prompt, got: #{prompt}"

        assert prompt =~ ~r/Ecto\.Repo|Ecto\.Adapters/,
               "expected step 4 (Repo / DB target discovery) in prompt, got: #{prompt}"

        assert prompt =~ ~r/Vibium|screenshot/i,
               "expected step 5 (Vibium screenshot dir verification) in prompt, got: #{prompt}"

        {:ok, context}
      end

      then_ "the Probe section appears before the Writing the Plan section", context do
        prompt = context.prompt

        probe_index =
          case :binary.match(prompt, "Probe") do
            {idx, _} -> idx
            :nomatch -> flunk("expected Probe section in prompt, got: #{prompt}")
          end

        write_index =
          case :binary.match(prompt, "Writing the Plan") do
            {idx, _} -> idx
            :nomatch -> flunk("expected Writing the Plan section in prompt, got: #{prompt}")
          end

        assert probe_index < write_index,
               "expected Probe to come before Writing the Plan, got Probe at #{probe_index}, Writing at #{write_index}"

        {:ok, context}
      end
    end
  end
end
