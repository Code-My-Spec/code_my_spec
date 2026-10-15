defmodule CodeMySpecSpex.Story1112.Criterion2036Spex do
  @moduledoc "Desktop setup explains missing pgvector before project creation."
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine

  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "Missing pgvector is actionable and blocks project creation", criterion: 2036 do
    scenario "The developer gets manual installation guidance when no agent is available" do
      given_ "pgvector is not installed on the desktop machine", context do
        context = DesktopSetupHelpers.without_pgvector(context)
        {:ok, view, _html} = live(context.conn, "/app")
        {:ok, Map.put(context, :view, view)}
      end

      when_ "the developer checks prerequisites", context do
        context.view
        |> element("[data-test='check-prerequisites']")
        |> render_click()

        render_async(context.view, 10_000)
        {:ok, context}
      end

      then_ "pgvector is shown as missing with installation instructions for this machine",
            context do
        assert has_element?(
                 context.view,
                 "[data-test='prerequisite'][data-name='pgvector'][data-state='missing']"
               )

        assert has_element?(
                 context.view,
                 "[data-name='pgvector'] [data-test='install-instructions']",
                 "pgvector"
               )

        instructions =
          context.view
          |> element("[data-name='pgvector'] [data-test='install-instructions']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.text()

        assert String.trim(instructions) != "pgvector"
        assert has_element?(context.view, "[data-name='pgvector'] [data-test='install-command']")
        {:ok, context}
      end

      then_ "unavailable agent help does not prevent manual installation", context do
        assert has_element?(context.view, "[data-test='setup-agent-unavailable']")

        assert has_element?(
                 context.view,
                 "[data-name='pgvector'] [data-test='install-instructions']",
                 "pgvector"
               )

        refute has_element?(
                 context.view,
                 "[data-test='accept-install-help']:not([disabled])"
               )

        {:ok, context}
      end

      then_ "setup stays at prerequisites and cannot create a project", context do
        assert has_element?(
                 context.view,
                 "[data-test='desktop-setup'][data-stage='prerequisites']"
               )

        refute has_element?(context.view, "[data-test='create-project']:not([disabled])")
        refute has_element?(context.view, "[data-test='project-connected']")
        refute read_machine_file!(context, context.command_log) =~ ~r/^cms new(?: |$)/m
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
