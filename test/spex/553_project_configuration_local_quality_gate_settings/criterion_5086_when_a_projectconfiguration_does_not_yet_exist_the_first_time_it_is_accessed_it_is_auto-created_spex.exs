defmodule CodeMySpecSpex.Story553.Criterion5086Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5086 — When a ProjectConfiguration does not yet exist, the first
  time it is accessed it is auto-created with the documented defaults.

  Defaults per the rules doc:
  - require_specs, require_reviews, require_unit_tests: true
  - compile_warnings: block
  - credo: block_changed
  - exunit: block_all
  - spex: off
  - spec_validation: block_changed
  - qa_validation: block_changed
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Default configuration is created on first access" do
    scenario "engineer opens a fresh project's configuration and sees all defaults" do
      # Setup gives us a fresh project with no ProjectConfiguration record.
      # The first access is the LiveView mount itself.

      when_ "the engineer opens the configuration page for the first time", context do
        {:ok, config_live, _html} =
          live(context.conn, ~p"/projects/#{context.project.name}/configuration")

        {:ok, Map.put(context, :config_live, config_live)}
      end

      then_ "all requirement toggles default to checked", context do
        assert has_element?(context.config_live, "[data-test='require-specs']:checked"),
               "require_specs must default to true"

        assert has_element?(context.config_live, "[data-test='require-reviews']:checked"),
               "require_reviews must default to true"

        assert has_element?(context.config_live, "[data-test='require-unit-tests']:checked"),
               "require_unit_tests must default to true"

        :ok
      end

      then_ "analyzer selects show the documented defaults", context do
        html = render(context.config_live)

        assert html =~ ~r/name="configuration\[compile_warnings\]"[^>]*>.*?<option[^>]*value="block"[^>]*selected/s,
               "compile_warnings must default to block"

        assert html =~ ~r/name="configuration\[credo\]"[^>]*>.*?<option[^>]*value="block_changed"[^>]*selected/s,
               "credo must default to block_changed"

        assert html =~ ~r/name="configuration\[exunit\]"[^>]*>.*?<option[^>]*value="block_all"[^>]*selected/s,
               "exunit must default to block_all"

        assert html =~ ~r/name="configuration\[spex\]"[^>]*>.*?<option[^>]*value="off"[^>]*selected/s,
               "spex must default to off"

        assert html =~
                 ~r/name="configuration\[spec_validation\]"[^>]*>.*?<option[^>]*value="block_changed"[^>]*selected/s,
               "spec_validation must default to block_changed"

        assert html =~
                 ~r/name="configuration\[qa_validation\]"[^>]*>.*?<option[^>]*value="block_changed"[^>]*selected/s,
               "qa_validation must default to block_changed"

        :ok
      end
    end
  end
end
