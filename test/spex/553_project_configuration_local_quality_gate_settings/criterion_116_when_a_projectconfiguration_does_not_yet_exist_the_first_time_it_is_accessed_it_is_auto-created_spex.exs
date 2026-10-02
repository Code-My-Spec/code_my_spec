defmodule CodeMySpecSpex.Story553.Criterion5086Spex do
  @moduledoc """
  Story 553 — Project Configuration: Local quality gate settings
  Criterion 5086 — When a ProjectConfiguration does not yet exist, the first
  time it is accessed it is auto-created with the documented defaults.

  Defaults per the rules doc:
  - compile_warnings: block
  - credo: block_changed
  - exunit: block_all
  - spex: off
  - qa_validation: block_changed
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
                 ~r/name="configuration\[compile_warnings\]"[^>]*>.*?<option[^>]*value="block"[^>]*selected/s,
               "compile_warnings must default to block"

        assert html =~
                 ~r/name="configuration\[credo\]"[^>]*>.*?<option[^>]*value="block_changed"[^>]*selected/s,
               "credo must default to block_changed"

        assert html =~
                 ~r/name="configuration\[exunit\]"[^>]*>.*?<option[^>]*value="block_all"[^>]*selected/s,
               "exunit must default to block_all"

        assert html =~
                 ~r/name="configuration\[spex\]"[^>]*>.*?<option[^>]*value="off"[^>]*selected/s,
               "spex must default to off"

        refute html =~ ~s(name="configuration[spec_validation]"),
               "specs are not validated any more (3aeb66cf), so there is nothing to configure"

        assert html =~
                 ~r/name="configuration\[qa_validation\]"[^>]*>.*?<option[^>]*value="block_changed"[^>]*selected/s,
               "qa_validation must default to block_changed"

        {:ok, context}
      end
    end
  end
end
