defmodule CodeMySpecSpex.Story1085.Criterion1733Spex do
  @moduledoc """
  Story 1085 — I'm told where my code has drifted from the plan
  Criterion 1733 — Drift is reported but doesn't block by default.

  This is about the stop hook's blocking decision once an architecture
  finding is already on the books, not about how the finding is
  produced — criteria 1729-1732 cover that end-to-end through the
  `CheckArchitecture` tool. Seeding the problem directly via
  `Fixtures.problem_fixture/2` is the documented exception in
  `bdd/spex/boundaries.md` for exactly this shape of scenario (see
  criterion 147 for the precedent).
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.ComponentGraphHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  @impl_path "lib/billing.ex"
  @fixture_dir "test/fixtures/validation/pipeline_clean_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Drift is reported but doesn't block by default", criterion: 1733 do
    scenario "an unplanned dependency finding does not block the stop" do
      given_ "Sam's project uses the default architecture setting", context do
        # given: already true — `setup :setup_active_project` creates a
        # fresh ProjectConfiguration and nothing in this spec changes
        # `architecture`, so it stays at the schema default.
        {:ok, context}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the code has an unplanned dependency", context do
        app = ComponentGraphHelpers.app(context)
        billing = ComponentGraphHelpers.design!(context, "#{app}.Billing")

        :ok =
          Environments.write_file(context.environment, @impl_path, """
          defmodule #{app}.Billing do
            @moduledoc false
          end
          """)

        HarnessHooks.write_file(context, @impl_path, """
        defmodule #{app}.Billing do
          @moduledoc false
        end
        """)

        Fixtures.problem_fixture(context.scope, %{
          source: "architecture",
          file_path: @impl_path,
          component_id: billing.id,
          line: 1,
          message: "Billing depends on Notifications without it being planned",
          category: "unplanned_dependency",
          rule: nil
        })

        {:ok, Map.put(context, :billing, billing)}
      end

      when_ "an agent finishes a change", context do
        HarnessHooks.land_analysis(
          context,
          "spex",
          Path.expand("test/fixtures/validation/spex_green.jsonl")
        )

        HarnessHooks.land_analysis(context, "exunit", fixture_path("exunit.json"))
        HarnessHooks.land_analysis(context, "compiler", fixture_path("compile.jsonl"))

        response = HarnessHooks.post_hook(context, "stop", %{})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the drift is reported", context do
        {:ok, _problems_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/problems?filter=architecture")

        assert html =~ "Billing depends on Notifications without it being planned",
               "expected the architecture finding on the Problems page"

        {:ok, context}
      end

      then_ "the agent is not blocked", context do
        refute context.response["decision"] == "block",
               "expected the default architecture mode not to block, got: #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp fixture_path(name), do: Path.expand(Path.join(@fixture_dir, name))
end
