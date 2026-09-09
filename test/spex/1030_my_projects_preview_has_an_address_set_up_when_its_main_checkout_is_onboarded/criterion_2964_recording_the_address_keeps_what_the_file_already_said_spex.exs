defmodule CodeMySpecSpex.Story1030.Criterion2964Spex do
  @moduledoc """
  Story 1030 — My project's preview has an address, set up when its main checkout
  is onboarded.
  Criterion 2964 — Recording the address keeps what the file already said.

  Rule: The address is recorded in the main checkout's own `.cms_harness.json`,
  merged into what that file already holds rather than written over it.

  By the time the address is recorded, that file already carries this copy's
  identity: which working copy it is, which project it serves, and the deploy
  key it was issued. A write that rebuilt the file from the fields it happened
  to know would take the rest with it.

  Both losses are quiet and neither is recoverable from the machine:

  - Without `project_id`, the copy falls through to `CMS_PROJECT_ID` — whatever
    session started the daemon happened to carry — and syncs its files into
    another project's rows with nothing suspicious in any log. That has happened
    here: `broken_oaths` reconciled into CodeMySpec's project for a whole day.
  - Without `deploy_key`, there is no second copy on the machine to restore it
    from. It is decrypted out of the server once, at onboarding.

  Not hypothetical. The first implementation of this write built a fresh
  four-key map and dropped both, and it shipped.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpec.Environments
  alias CodeMySpec.Workspaces.PreviewTunnel

  setup :register_log_in_setup_account
  setup :setup_active_project

  @harness_config ".cms_harness.json"
  @deploy_key "spex-2964-deploy-key-not-recoverable"

  spex "Recording a preview address does not cost the checkout its identity" do
    scenario "Recording the address keeps what the file already said" do
      given_ "a checkout whose config already holds its project and its key", context do
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
              %{
                working_copy_id: reply.working_copy_id,
                harness_id: reply.working_copy_id,
                project_id: context.project.id,
                deploy_key: @deploy_key
              },
              pretty: true
            )
          )

        Req.Test.stub(PreviewTunnel, &cloudflare_response/1)

        {:ok, context}
      end

      when_ "onboarding records where its preview answers", context do
        Mix.Task.reenable("cms.harness.onboard")

        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the address is there", context do
        config = read_config(context)

        assert config["preview_url"],
               "no address was recorded, so this scenario cannot say anything about " <>
                 "what recording one preserves. Got: #{inspect(config)}"

        {:ok, context}
      end

      then_ "the project it serves is unchanged", context do
        config = read_config(context)

        assert config["project_id"] == context.project.id,
               "recording the address dropped `project_id`. That copy now resolves " <>
                 "its project from CMS_PROJECT_ID and syncs its files into whatever " <>
                 "project the session that started the daemon was working on. " <>
                 "Got: #{inspect(config)}"

        {:ok, context}
      end

      then_ "the credential it was issued is unchanged", context do
        config = read_config(context)

        assert config["deploy_key"] == @deploy_key,
               "recording the address dropped `deploy_key`. It is decrypted out of " <>
                 "the server once, at onboarding — there is no second copy on this " <>
                 "machine to restore it from. Got: #{inspect(config)}"

        {:ok, context}
      end
    end
  end

  defp read_config(context) do
    {:ok, contents} = Environments.read_file(context.environment, @harness_config)
    Jason.decode!(contents)
  end

  defp cloudflare_response(conn),
    do: cloudflare_json(conn, String.contains?(conn.request_path, "cfd_tunnel"))

  defp cloudflare_json(conn, true) do
    Req.Test.json(conn, %{
      "success" => true,
      "errors" => [],
      "result" => %{"id" => "c0ffee11-0000-4000-8000-000000002964"}
    })
  end

  defp cloudflare_json(conn, false),
    do:
      Req.Test.json(conn, %{"success" => true, "errors" => [], "result" => %{"id" => "rec-2964"}})
end
