defmodule CodeMySpecSpex.Story1030.Criterion2961Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2961 — The main checkout comes out of onboarding with an address.

  Rule: Onboarding a project's main checkout records where its preview answers.

  The founder never asks for this. The whole claim of the story is that the
  preview "appears on my screen without my finding or configuring anything", and
  the only moment anything knows both that this machine exists and that it is
  the one serving this project is when its checkout is onboarded. Miss that
  moment and the address has to be entered by hand later, which is the errand
  the story exists to remove.

  ## Why the address is asserted in the checkout's own file

  Because that is where it has to survive. The harness reports it to the server
  on join, so the server's copy is downstream of this one — asserting the server
  row would pass just as well if onboarding had written the address nowhere and
  something else had put it in the database.

  ## Cloudflare is stubbed; onboarding is not

  The surface under test is onboarding. Cloudflare is a third party on the other
  side of it, and `config/test.exs` already pins this client's plug so a
  forgotten stub raises instead of provisioning a real tunnel on the real zone —
  which this project has shipped once before. Stubbing the surface under test
  would make the spec a tautology; stubbing the API it calls is what keeps the
  spec from creating infrastructure.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @tunnel_id "b0a71e11-0000-4000-8000-00000000968a"

  spex "Onboarding the main checkout gives the project a preview address" do
    scenario "The main checkout comes out of onboarding with an address" do
      given_ "a checkout of the project, and Cloudflare answering", context do
        :ok = Environments.register(context.project.id, context.environment)

        # An id already on the copy, so the task does not go to the network to
        # mint one. Written through the same surface the task reads it from —
        # the same arrangement criterion 2352's spec uses and for the same
        # reason.
        :ok =
          Environments.write_file(
            context.environment,
            @harness_config,
            Jason.encode!(
              %{working_copy_id: "spex-harness-2961", project_id: context.project.id},
              pretty: true
            )
          )

        Req.Test.stub(PreviewTunnel, fn conn ->
          if String.contains?(conn.request_path, "cfd_tunnel") do
            Req.Test.json(conn, %{"success" => true, "result" => %{"id" => @tunnel_id}})
          else
            Req.Test.json(conn, %{"success" => true, "result" => %{"id" => "rec-2961"}})
          end
        end)

        {:ok, context}
      end

      when_ "the engineer onboards it", context do
        Mix.Task.reenable("cms.harness.onboard")

        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the checkout's own config names where its preview answers", context do
        assert {:ok, contents} = Environments.read_file(context.environment, @harness_config)

        config = Jason.decode!(contents)

        assert url = config["preview_url"],
               "onboarding recorded no preview address. The panel reads this, so the " <>
                 "founder is told no preview is running for a project that has one — " <>
                 "and the only way to fix it is the manual step this story removes. " <>
                 "Got: #{contents}"

        assert url =~ "preview-",
               "the address is not one of ours. It has to sit on our own domain: the " <>
                 "proxy recognises a preview by that prefix, the frame-src policy is " <>
                 "derived from the same base domain, and Safari drops the framed " <>
                 "app's session cookie across a registrable domain. Got: #{url}"

        {:ok, context}
      end

      then_ "the identity it was onboarded with is still there", context do
        assert {:ok, contents} = Environments.read_file(context.environment, @harness_config)

        config = Jason.decode!(contents)

        assert config["project_id"] == context.project.id,
               "recording the preview address dropped the project. That copy now " <>
                 "resolves its project from CMS_PROJECT_ID — whatever session started " <>
                 "the daemon happened to carry — and syncs its files into another " <>
                 "project's rows with nothing suspicious in any log. Got: #{contents}"

        {:ok, context}
      end
    end
  end
end
