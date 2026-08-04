defmodule CodeMySpecSpex.Story992.Criterion8239Spex do
  @moduledoc """
  Story 992 — My images are built on infrastructure I never maintain
  Criterion 8239 — A deploy does not pay for the toolchain every time.

  A builder is created per build, so whatever it has to install, it installs on
  every deploy. Starting from a bare OS means `apt-get install docker` before
  any work begins: a minute or two of Sam's deploy, and a dependency on apt
  mirrors being up at that moment — a deploy that fails for reasons that have
  nothing to do with his code.

  Checked against the provider rather than the docs: every Hetzner system image
  is the same 5GB minimal cloud image, so a "lighter" OS is not lighter. The
  weight that matters is what must be installed before the box can do its job,
  which is why the builder boots from the Docker app image instead.

  Asserted on what the builder booted from, because that is the decision — the
  time saved is a consequence of it, and timing a build would measure Hetzner.

  Surface: `CodeMySpecWeb.ProvisioningLive`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers
  setup :real_working_directory

  spex "A deploy does not pay for the toolchain every time" do
    scenario "the builder boots from an image that already has the toolchain" do
      given_ "Sam has a project ready to deploy", context do
        {:ok, built_deploy_run(context)}
      end

      when_ "he deploys", context do
        view = mount_provisioning(context)
        view |> element("[data-test='start-setup']") |> render_click()

        {:ok, Map.put(context, :html, await_provisioning(view))}
      end

      then_ "the builder booted from a pre-warmed image, not a bare OS", context do
        builder =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='builder']")

        assert builder != [], "the deploy did not record what the builder booted from"

        assert [booted_from] = Floki.attribute(builder, "data-booted-from")

        # The Docker app image. A bare OS would name a distribution, and every
        # deploy would then install the toolchain before starting work.
        assert booted_from =~ "docker",
               "the builder booted from #{booted_from}, so every deploy pays to install " <>
                 "the toolchain before it can build anything"

        {:ok, context}
      end
    end
  end
end
