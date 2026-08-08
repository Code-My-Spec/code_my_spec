defmodule CodeMySpecSpex.Story970.Criterion7977Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7977 — The health check answers without session, auth or database.

  The generated health route sits outside every router pipeline. The proxy's
  probe gates the traffic swap, so a health check that needs a session, an
  authenticated user, or a database round-trip fails deploys for reasons
  unrelated to whether the app is up — and takes the database down with the
  app when it matters most.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem — the generated project's router.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # A real directory on disk, shared with the page. The generator writes
  # through the project's registered environment; a spex holding its own
  # in-memory one reads an empty tree and concludes nothing was generated.
  setup :real_working_directory

  spex "The health check answers without session, auth or database" do
    scenario "the health route is declared outside all pipelines" do
      given_ "Sam generates a project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he looks at how the health path is routed", context do
        entries = project_tree(context.environment)

        router_path =
          Enum.find(entries, fn path -> String.ends_with?(path, "router.ex") end)

        assert router_path != nil,
               "expected the generated project to have a router, entries: #{inspect(entries)}"

        {:ok, body} = Environments.read_file(context.environment, router_path)

        {:ok, context |> Map.put(:router, body) |> Map.put(:router_path, router_path)}
      end

      then_ "the health route is declared", context do
        # Anchor: a health route exists at all.
        assert context.router =~ ~r/["\/]health|["\/]up/,
               "expected a health route in #{context.router_path}"

        {:ok, context}
      end

      then_ "its scope pipes through nothing", context do
        # Find the scope block containing the health route and assert it has
        # no pipe_through. A health route inside the :browser scope would
        # carry session and CSRF plugs.
        health_scope =
          context.router
          |> String.split(~r/\n\s*scope /)
          |> Enum.find(fn chunk -> chunk =~ ~r/["\/]health|["\/]up/ end)

        assert health_scope != nil,
               "expected to locate the scope declaring the health route"

        refute health_scope =~ ~r/pipe_through/,
               "expected the health route's scope to pipe through nothing, got:\n#{health_scope}"

        {:ok, context}
      end
    end
  end
end
