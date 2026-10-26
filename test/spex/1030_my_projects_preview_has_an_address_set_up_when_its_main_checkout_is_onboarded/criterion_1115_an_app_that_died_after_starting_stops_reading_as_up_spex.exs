defmodule CodeMySpecSpex.Story1030.Criterion1115Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main
  checkout is onboarded.
  Criterion 1115 — An app that died after starting stops reading as up.

  Rule: `Workspaces.state/1` asks the runner whether the container is alive
  at all before it asks anything about serving — a workspace row stored as
  `:running` is a claim about a container that may no longer exist (pruned,
  rebooted, torn down), not a fact that stays true once written. Reading the
  stored status back as still-up would show a founder his app running when
  the thing serving it is gone.

  Surface: the preview page, re-opened after the container dies -- state is
  computed fresh on mount, not carried over from the row.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An app that died after starting stops reading as up", criterion: 1115 do
    scenario "An app that died after starting stops reading as up" do
      given_ "the app is running", context do
        :ok = Fixtures.workspace_in(context.scope, context.project.id, :running)

        {:ok, view, html} = live(context.conn, "/build/preview")

        assert has_element?(view, "[data-test='preview-frame']"),
               "the precondition did not hold -- expected the app to read as running " <>
                 "before it dies, got: #{html}"

        {:ok, context}
      end

      when_ "the container dies", context do
        :ok = Fixtures.put_workspace_alive(false)

        {:ok, view, html} = live(context.conn, "/build/preview")

        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "it no longer reads as up", context do
        refute has_element?(context.view, "[data-test='preview-frame']"),
               "a dead container's app was still framed as running, got: #{context.html}"

        refute has_element?(context.view, "[data-test='preview-address']"),
               "a dead container's app still showed an address to open, got: #{context.html}"

        {:ok, context}
      end

      then_ "and it reads as down, not as still coming up", context do
        assert has_element?(context.view, "[data-test='preview-down']"),
               "expected a container that died after running to read as down, " <>
                 "got: #{context.html}"

        refute has_element?(context.view, "[data-test='preview-starting']"),
               "a dead container was reported as still coming up, which tells a founder " <>
                 "to wait for something that is not going to start"

        {:ok, context}
      end
    end
  end
end
