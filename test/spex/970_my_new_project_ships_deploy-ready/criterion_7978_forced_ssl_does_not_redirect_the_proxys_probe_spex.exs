defmodule CodeMySpecSpex.Story970.Criterion7978Spex do
  @moduledoc """
  Story 970 — My new project ships deploy-ready
  Criterion 7978 — Forced SSL does not redirect the proxy's probe.

  The trap this criterion exists for, straight from our own runbook: the
  proxy's health probe hits the app port directly over plain HTTP with no
  `X-Forwarded-Proto` header. An app configured with `force_ssl` and no
  exclusion for the health path 301s that probe, the swap never completes,
  and the deploy fails for a reason that has nothing to do with the app
  being broken.

  So a generated project that sets `force_ssl` must also exclude the health
  path in the same breath.

  Surface note: see criterion 7979 — these describe the cms_new generator's
  output, which lives outside the spex boundary.

  Surface: filesystem — the generated project's runtime configuration.
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

  spex "Forced SSL does not redirect the proxy's probe" do
    scenario "force_ssl, where configured, excludes the health path" do
      given_ "Sam generates a project", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='generate-project']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the proxy would probe the health path over plain HTTP", context do
        entries = project_tree(context.environment)

        configs =
          Enum.filter(entries, fn path ->
            String.contains?(path, "config/") and Path.extname(path) == ".exs"
          end)

        bodies =
          Map.new(configs, fn path ->
            {:ok, body} = Environments.read_file(context.environment, path)
            {path, body}
          end)

        {:ok, Map.put(context, :configs, bodies)}
      end

      then_ "any force_ssl configuration excludes the health path", context do
        # Anchor: configuration was generated at all, so this is not passing
        # on an empty set.
        assert map_size(context.configs) > 0,
               "expected the generated project to carry configuration files"

        with_force_ssl =
          context.configs
          |> Enum.filter(fn {_path, body} -> body =~ ~r/force_ssl/ end)

        for {path, body} <- with_force_ssl do
          assert body =~ ~r/exclude:/,
                 "expected #{path} to exclude paths from force_ssl so the proxy probe is not redirected"

          # `paths:`, not just a list mentioning health. This asserted the
          # looser form and so accepted `exclude: ["/health"]`, which is what
          # the generator emitted — and `Plug.SSL.validate_exclude!/1` turns a
          # bare string into `{:hosts, [string]}`, so that excluded a host
          # named "/health", matched nothing, and left the probe redirected.
          #
          # `DeployBoilerplate.@health_exclusion` requires `paths:` for exactly
          # this reason, learned from a deploy that stalled on "target failed
          # to become healthy". This criterion is the one that should have
          # caught the generator disagreeing with it, and could not.
          assert body =~ ~r/paths:\s*\[[^\]]*(health|up)/,
                 "expected #{path} to exclude the health path via `paths:`, which is the " <>
                   "only form Plug.SSL reads, got:\n#{Regex.run(~r/force_ssl.*/, body) |> inspect()}"
        end

        {:ok, Map.put(context, :with_force_ssl, with_force_ssl)}
      end

      then_ "the probe would receive 200 rather than a redirect", context do
        # The generator's runtime.exs always sets force_ssl in prod
        # (`DeployArtifacts.runtime_config/2`), so this never holds trivially
        # on an absent force_ssl — the health exclusion checked above is what
        # actually keeps the probe from being redirected.
        assert context.with_force_ssl != [],
               "expected force_ssl to actually be configured, so the health " <>
                 "exclusion checked above is not proving something vacuous"

        {:ok, context}
      end
    end
  end
end
