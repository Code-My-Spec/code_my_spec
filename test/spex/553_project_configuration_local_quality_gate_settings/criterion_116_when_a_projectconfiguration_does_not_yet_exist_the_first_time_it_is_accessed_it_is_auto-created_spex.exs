defmodule CodeMySpecSpex.Story553.Criterion5086Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5086 — When a ProjectConfiguration does not yet exist, the first
  time it is accessed it is auto-created with the documented defaults.

  Defaults: QA brief validation and architecture drift on, advisory findings
  do not block promotion.
  There are no per-analyzer blocking modes: problems gate at promotion only,
  on the fixed four sources (John, 2026-10-18).
  """

  use CodeMySpecSpex.Case
  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Default configuration is created on first access", criterion: 116 do
    scenario "engineer opens a fresh project's configuration and sees all defaults" do
      # Setup gives us a fresh project with no ProjectConfiguration record.
      # The first access is the LiveView mount itself.

      when_ "the engineer opens the configuration page for the first time", context do
        {:ok, config_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/configuration")

        {:ok, Map.put(context, :config_live, config_live)}
      end

      then_ "retired component workflow toggles are absent", context do
        refute has_element?(context.config_live, "[data-test='require-specs']")
        refute has_element?(context.config_live, "[data-test='require-reviews']")
        refute has_element?(context.config_live, "[data-test='require-unit-tests']")
        {:ok, context}
      end

      then_ "analyzer selects show the documented defaults", context do
        html = render(context.config_live)

        assert html =~
                 ~r/name="configuration\[qa_validation\]"[^>]*>.*?<option[^>]*value="on"[^>]*selected/s,
               "QA brief validation must default to on"

        assert html =~
                 ~r/name="configuration\[advisory_findings\]"[^>]*>.*?<option[^>]*value="dont_block"[^>]*selected/s,
               "advisory findings must not block promotion by default"

        assert html =~
                 ~r/name="configuration\[architecture\]"[^>]*>.*?<option[^>]*value="on"[^>]*selected/s,
               "architecture drift must default to on"

        for retired <- ~w(compile_warnings credo exunit spex spec_validation) do
          refute html =~ ~s(name="configuration[#{retired}]"),
                 "#{retired} has no setting: problems gate at promotion on the fixed four sources"
        end

        {:ok, context}
      end
    end
  end
end
