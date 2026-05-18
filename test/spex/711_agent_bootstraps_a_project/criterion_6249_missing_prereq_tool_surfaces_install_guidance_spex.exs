defmodule CodeMySpecSpex.Story711.Criterion6249Spex do
  @moduledoc """
  Story 711 — Agent bootstraps a project
  Criterion 6249 — Missing prereq tool surfaces install guidance.

  When `Init.PhoenixInstaller.evaluate/2` shells out and `mix phx.new
  --version` returns a non-zero exit, the sub-step returns `{:ok,
  :invalid, detail}` with a detail string that names the
  `mix archive.install hex phx_new` remediation.

  Surface: `AgentTasks.Init.PhoenixInstaller.evaluate/2`. ExCliVcr
  replays `init_phx_installer_missing.json` so the test doesn't
  depend on the host having or lacking the phx_new archive.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Prereq sub-steps satisfy on a successful version-probe shell out" do
    scenario "Missing prereq tool surfaces install guidance" do
      given_ "the active toolchain has no phx_new archive installed",
             context do
        {:ok, context}
      end

      when_ "the agent calls Init.PhoenixInstaller.evaluate on the scope",
            context do
        result =
          use_cmd_cassette "init_phx_installer_missing", record: :none do
            Fixtures.init_phoenix_installer_evaluate(context.scope, %{})
          end

        {:ok, Map.put(context, :evaluate_result, result)}
      end

      then_ "the result is {:ok, :invalid, detail}", context do
        assert match?({:ok, :invalid, detail} when is_binary(detail), context.evaluate_result),
               "expected {:ok, :invalid, <detail>}, got: #{inspect(context.evaluate_result)}"

        {:ok, Map.put(context, :detail, elem(context.evaluate_result, 2))}
      end

      and_ "the detail names `mix archive.install hex phx_new`", context do
        assert context.detail =~ ~r/mix archive\.install hex phx_new/,
               "expected detail to name the install command, got: #{inspect(context.detail)}"

        {:ok, context}
      end
    end
  end
end
