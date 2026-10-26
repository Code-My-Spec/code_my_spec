defmodule CodeMySpecSpex.Story1146.Criterion2380Spex do
  @moduledoc "Story 1146 — Sam receives the copyable setup bundle for a supported generation target."
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam receives a complete target setup", criterion: 2380 do
    scenario "Sam adds Codex Cloud for his Phoenix generation target" do
      given_ "Sam has a supported project and is on Dev boxes", context do
        {:ok, view, _html} = open_dev_boxes(context.conn, context.project)
        view |> element("[data-test='add-dev-box']") |> render_click()

        view
        |> form("[data-test='add-dev-box-form']", dev_box: %{provider: "codex_cloud"})
        |> render_change()

        assert has_element?(view, "[data-test='codex-cloud-platform']", "x86_64 Linux")
        assert has_element?(view, "[data-test='codex-cloud-platform']", "cms-linux-x64.tar.gz")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam adds a Codex Cloud box for the Phoenix target", context do
        context.view
        |> form("[data-test='add-dev-box-form']",
          dev_box: %{name: "codex-generation", provider: "codex_cloud", target: "phoenix"}
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "installation, startup, environment and network settings can be copied separately",
            context do
        for key <- ~w(setup-script startup-script setup-environment setup-hosts) do
          assert has_element?(context.view, "[data-test='#{key}']")
          assert has_element?(context.view, "[data-test='copy-#{key}']")
        end

        assert has_element?(context.view, "[data-test='setup-platform']", "x86_64 Linux")
        assert has_element?(context.view, "[data-test='setup-platform']", "cms-linux-x64.tar.gz")
        html = render(context.view)
        refute html =~ "cms-linux-arm64"
        refute html =~ "linux/aarch64"
        assert html =~ "codex-generation"
        {:ok, context}
      end
    end
  end
end
