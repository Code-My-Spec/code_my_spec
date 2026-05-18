defmodule CodeMySpecSpex.Story711.Criterion6247Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6247 — Init.command renders done/total progress and inlines only incomplete prompts.

  When the agent calls `AgentTasks.Init.command/2` with a scope where
  five of the six sub-steps are :valid and Init.Auth is :invalid (no
  OAuth credentials seeded), the returned prompt:
    1. Shows `5/6` progress in the header.
    2. Lists every sub-step in a checklist with done or pending state.
    3. Inlines only the Auth sub-step's prompt (not the others').
    4. Marks Auth as the next actionable.

  Surface: `AgentTasks.Init.command/2`. The three prereq sub-steps
  shell out via `System.cmd`; ExCliVcr replays
  `init_all_prereqs_pass.json` so each probe reports a passing version.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Init aggregates sub-steps into one checklist with progress and inlined prompts" do
    scenario "Init.command renders done/total progress and inlines only incomplete prompts" do
      given_ "the working directory has the full Phoenix project shape (mix.exs, lib/, config/)",
             context do
        File.mkdir_p!(Path.join(context.scope.cwd, "config"))
        {:ok, context}
      end

      given_ "no OAuth credentials are seeded for the active user (Auth will be the only incomplete sub-step)",
             context do
        {:ok, context}
      end

      when_ "the agent calls Init.command on the scope", context do
        prompt =
          use_cmd_cassette "init_all_prereqs_pass", record: :none do
            {:ok, prompt} = Fixtures.init_command(context.scope, %{})
            prompt
          end

        {:ok, Map.put(context, :init_prompt, prompt)}
      end

      then_ "the prompt header reports 5/6 progress", context do
        assert context.init_prompt =~ ~r/5\s*\/\s*6/,
               "expected `5/6` progress in prompt, got:\n#{context.init_prompt}"

        {:ok, context}
      end

      and_ "every sub-step name appears in the checklist", context do
        for name <- ~w(Auth Elixir Phoenix installer Postgresql Phoenix project Cli config) do
          assert context.init_prompt =~ name,
                 "expected `#{name}` in checklist, got:\n#{context.init_prompt}"
        end

        {:ok, context}
      end

      and_ "only the Auth sub-step has its per-step prompt inlined", context do
        assert context.init_prompt =~ ~r/Authenticate with CodeMySpec/,
               "expected Auth sub-step prompt inlined, got:\n#{context.init_prompt}"

        refute context.init_prompt =~ ~r/Install Elixir 1\.18/,
               "expected Elixir sub-step prompt to NOT be inlined (it's done), got:\n#{context.init_prompt}"

        refute context.init_prompt =~ ~r/Install Phoenix Installer/,
               "expected PhoenixInstaller sub-step prompt to NOT be inlined (it's done), got:\n#{context.init_prompt}"

        {:ok, context}
      end

      and_ "the Auth sub-step is marked as the next actionable", context do
        assert context.init_prompt =~ ~r/Auth.*<- next/,
               "expected Auth marked as `<- next`, got:\n#{context.init_prompt}"

        {:ok, context}
      end
    end
  end
end
