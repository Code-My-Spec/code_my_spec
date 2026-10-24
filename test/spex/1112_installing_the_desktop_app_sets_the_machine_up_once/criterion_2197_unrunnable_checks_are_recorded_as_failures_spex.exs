defmodule CodeMySpecSpex.Story1112.Criterion2197Spex do
  @moduledoc "Missing agent commands are failed checks, never successful installation results."
  use CodeMySpecSpex.Case, async: false

  spex "An unavailable agent is recorded as a failed check", criterion: 2197 do
    scenario "Neither CLI is installed" do
      given_ "a machine with no CLI executables on its path", context do
        opts = CmsHarnessTest.SetupFixture.isolated_history()
        {:ok, Map.put(context, :root, Path.dirname(opts[:directory]))}
      end

      when_ "the shared prerequisites catalog checks the agents", context do
        results = CmsHarnessTest.SetupFixture.agent_installations(context.root)
        {:ok, Map.put(context, :results, results)}
      end

      then_ "both installations are unavailable with a diagnostic", context do
        for key <- ["codex", "claude"] do
          assert %{installed?: false, error: error} = context.results[key]
          assert is_binary(error)
        end

        {:ok, context}
      end
    end
  end
end
