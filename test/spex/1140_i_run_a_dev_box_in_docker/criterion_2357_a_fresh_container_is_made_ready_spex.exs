defmodule CodeMySpecSpex.Story1140.Criterion2357Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2357 — A fresh container is made ready.

  A fresh Ubuntu container is a clean machine, so it is driven the way 1133
  drives any clean machine: the same prerequisite steps, whose outcomes are
  recorded in the setup results file (`CmsHarness.Setup`).
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A new Docker box runs the same setup as any box", criterion: 2357 do
    scenario "The container starts from the clean image" do
      given_ "a new Docker box starts from the clean image", context do
        {:ok, view, _} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "its setup runs", context do
        context.view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "the same setup steps run, each outcome recorded", context do
        assert has_element?(context.view, "[data-test='prerequisite'][data-name='postgres']")
        assert has_element?(context.view, "[data-test='setup-results-file'][data-path]")

        [path] =
          context.view
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        assert {:ok, _results} = Environments.read_file(context.machine_environment, path)
        {:ok, context}
      end

      then_ "and the box's app is reachable when setup finishes", context do
        refute has_element?(context.view, "[data-test='prerequisite'][data-state='failed']"),
               "setup finished with a failed step"

        {:ok, context}
      end
    end
  end
end
