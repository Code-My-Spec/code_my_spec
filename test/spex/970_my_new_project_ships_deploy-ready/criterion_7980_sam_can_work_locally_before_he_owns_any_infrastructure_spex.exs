defmodule CodeMySpecSpex.Story970.Criterion7980Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7980 — Sam can work locally before he owns any infrastructure.

  A generated project boots and serves with no provider credentials
  configured. Nothing demands a Hetzner, Cloudflare or Resend account to run
  it on a laptop — deploy-ready must not mean deploy-required, or the
  generator has made getting started harder rather than easier.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem — the generated project's configuration.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @providers ~w(HETZNER CLOUDFLARE RESEND)

  setup :register_log_in_setup_account
  setup :setup_active_project
  # A real directory on disk, shared with the page. The generator writes
  # through the project's registered environment; a spex holding its own
  # in-memory one reads an empty tree and concludes nothing was generated.
  setup :real_working_directory

  spex "Sam can work locally before he owns any infrastructure" do
    scenario "the project runs locally with no provider credentials configured" do
      given_ "Sam has generated a project and configured no provider credentials", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        entries = project_tree(context.environment)

        {:ok, context |> Map.put(:view, view) |> Map.put(:entries, entries)}
      end

      when_ "he starts it locally", context do
        html =
          context.view
          |> element("[data-test='local-boot-probe']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it boots and serves requests", context do
        boot =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='local-boot-result']")

        # Anchor: a local boot was actually attempted.
        assert boot != [], "expected the local boot probe to be recorded"

        state = boot |> Floki.attribute("data-state") |> List.first()

        assert state == "serving",
               "expected the generated project to boot and serve locally, got #{inspect(state)}"

        {:ok, context}
      end

      then_ "nothing demands a Hetzner, Cloudflare or Resend account", context do
        dev_configs =
          Enum.filter(context.entries, fn path ->
            String.contains?(path, "config/") and
              (String.contains?(path, "dev") or String.contains?(path, "config.exs"))
          end)

        assert dev_configs != [],
               "expected the generated project to carry development configuration"

        for path <- dev_configs do
          {:ok, body} = Environments.read_file(context.environment, path)

          for provider <- @providers do
            refute body =~ ~r/System\.fetch_env!\(\s*"#{provider}[A-Z_]*"/,
                   "expected #{path} not to require a #{provider} credential to boot locally"

            refute body =~ ~r/env!\(\s*"#{provider}[A-Z_]*"[^)]*\)\s*$/m,
                   "expected #{path} not to hard-require a #{provider} credential"
          end
        end

        {:ok, context}
      end
    end
  end
end
