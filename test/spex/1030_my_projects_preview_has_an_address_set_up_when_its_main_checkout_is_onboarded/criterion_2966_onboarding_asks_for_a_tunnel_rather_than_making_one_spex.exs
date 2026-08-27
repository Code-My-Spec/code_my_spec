defmodule CodeMySpecSpex.Story1030.Criterion2966Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2966 — Onboarding asks for a tunnel rather than making one.

  Rule: The tunnel is created by the server, because the credential that creates
  it is ours and never leaves it.

  This is forced rather than chosen. Story 891's rule is "onboarding ships where
  a target application can run it, not only where CodeMySpec can" — it lives in
  `client_utils` precisely so a generated Phoenix app can onboard itself. A
  generated app has no CodeMySpec Cloudflare credential and must never be given
  one, so it cannot create a tunnel. It asks; the server creates and answers.

  Same shape as minting a harness id, which already posts to the server for the
  same reason.

  ## The credential is what this scenario is really about

  The address landing is criterion 2961's claim. What is asserted here is that
  the checkout got a working preview *without* holding anything that could
  provision one — because the alternative design, shipping our Cloudflare token
  to every generated app, would work perfectly and hand every customer the keys
  to our zone.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "a11ce000-0000-4000-8000-000000002966"

  spex "A checkout gets a tunnel without being able to make one" do
    scenario "Onboarding asks for a tunnel rather than making one" do
      given_ "a checkout holding no credential of ours, and Cloudflare answering",
             context do
        :ok = Environments.register(context.project.id, context.environment)

        # A real working copy, minted the way one actually is - a harness joining
        # for it. Onboarding looks the copy up to decide whether it is the
        # project's main checkout, so an invented id is refused before any of
        # this is reached.
        reply = join_working_copy(context, "/workspace/main", "main")

        :ok =
          Environments.write_file(
            context.environment,
            @harness_config,
            Jason.encode!(
              %{working_copy_id: reply.working_copy_id, project_id: context.project.id},
              pretty: true
            )
          )

        test_pid = self()

        Req.Test.stub(PreviewTunnel, fn conn ->
          send(test_pid, {:cloudflare_called, conn.request_path})

          if String.contains?(conn.request_path, "cfd_tunnel") do
            Req.Test.json(conn, %{"success" => true, "result" => %{"id" => @tunnel_id}})
          else
            Req.Test.json(conn, %{"success" => true, "result" => %{"id" => "rec-2966"}})
          end
        end)

        {:ok, context}
      end

      when_ "the engineer onboards it", context do
        Mix.Task.reenable("cms.harness.onboard")

        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the checkout comes away able to carry a preview", context do
        {:ok, contents} = Environments.read_file(context.environment, @harness_config)
        config = Jason.decode!(contents)

        assert config["preview_url"],
               "the checkout got no address, so asking the server for one did not " <>
                 "happen or did not answer. Got: #{contents}"

        assert config["preview_tunnel_id"],
               "the checkout got an address with no tunnel behind it. The address " <>
                 "would resolve to an edge holding no connection to this app, and the " <>
                 "frame would sit blank with nothing saying why."

        {:ok, context}
      end

      then_ "the checkout was never given anything that could provision one", context do
        {:ok, contents} = Environments.read_file(context.environment, @harness_config)

        refute contents =~ "CLOUDFLARE",
               "our Cloudflare credential was written into the checkout. It would " <>
                 "then sit in every generated application, and any customer could " <>
                 "write records on our zone. Got: #{contents}"

        assert_received {:cloudflare_called, path},
                        "nothing reached Cloudflare at all, so no tunnel exists and " <>
                          "the address points nowhere"

        assert path =~ "cfd_tunnel" or path =~ "dns_records"

        {:ok, context}
      end
    end
  end
end
