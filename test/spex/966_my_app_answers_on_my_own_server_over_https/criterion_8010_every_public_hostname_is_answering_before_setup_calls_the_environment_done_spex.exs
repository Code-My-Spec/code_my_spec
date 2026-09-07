defmodule CodeMySpecSpex.Story966.Criterion8010Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8010 — Every public hostname is answering before setup calls the
  environment done.

  Amended 2026-08. This criterion used to read "Sam finds out when his site
  stops answering", and asked for an uptime monitor on every public hostname.
  Setup does not install one: `Sequence` records why — the step needed an
  account, an API key and a notification target only a person can supply, so
  it paused on every run and no setup could report complete. It was removed
  rather than left pausing.

  What survives is the half setup genuinely does: it verifies each public
  hostname answers before calling that environment done, so Sam is never
  handed an environment that was already dark. Watching it afterwards is
  still his to arrange, and this criterion no longer pretends otherwise.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_working_directory
  # Fakes rather than cassettes. What this asserts on — whether a hostname
  # answers — is injected by `stage_deploy/2` either way.
  setup :fake_providers

  spex "Every public hostname is answering before setup calls the environment done" do
    scenario "the hostname is checked, and the check is what makes the step done" do
      given_ "an environment has deployed", context do
        context = stage_deploy(context, :ok)

        # The check is what makes the step done, which means the step has to
        # run — and `run_step/3` returns early when verify is already
        # satisfied. A hostname that answers from the start would make this
        # criterion assert on a step that did nothing.
        context = certificate_issued_by_the_step(context)

        view = mount_provisioning(context)

        # Set after the mount: a domain present at mount makes `load/2` read the
        # mail panel, which calls Resend outside every cassette.
        own_domain(context.project, "staged.example.com")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the environment", context do
        # "uat" — the environment `stage_deploy/2` staged above.
        html =
          context.view
          |> element(
            "[data-test='setup-step'][data-step='tls'][data-environment='uat'] [data-test='run-step']"
          )
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "every hostname setup recorded answered", context do
        verifications =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='environment-verification']")

        # Anchor: a verification happened at all. Without this, the loop below
        # passes vacuously on an empty list, which is exactly how a step that
        # checked nothing reads as a step that checked everything.
        assert verifications != [], "expected setup to record the hostname check"

        for verification <- verifications do
          host = verification |> Floki.attribute("data-host") |> List.first()
          status = verification |> Floki.attribute("data-status") |> List.first()

          assert is_binary(host) and host != "",
                 "expected the verification to name the hostname it requested"

          assert status == "200",
                 "expected #{inspect(host)} to answer 200, got #{inspect(status)}"
        end

        {:ok, context}
      end

      then_ "the environment is done", context do
        assert context.html =~ ~r/data-step="tls"[^>]*data-state="done"/,
               "expected the verified environment to be called done"

        {:ok, context}
      end
    end

    scenario "an environment whose hostname does not answer is not called done" do
      given_ "an environment whose hostname does not answer", context do
        # The same staging as above but for the probe, which reports 503. The
        # difference between the two scenarios is one response, so whatever
        # makes the first pass cannot also make this one pass.
        own_domain(context.project, "staged.example.com")
        context = stage_deploy(context, :health_fails)
        view = mount_provisioning(context)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup verifies the environment", context do
        # "uat" — the environment `stage_deploy/2` staged above.
        html =
          context.view
          |> element(
            "[data-test='setup-step'][data-step='tls'][data-environment='uat'] [data-test='run-step']"
          )
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "setup does not call it done", context do
        refute context.html =~ ~r/data-step="tls"[^>]*data-state="done"/,
               "expected a hostname that does not answer to leave the environment unfinished"

        {:ok, context}
      end

      then_ "and says which hostname did not answer", context do
        # Otherwise Sam has an environment that stopped short and no idea
        # which of two hostnames to look at.
        assert context.html =~ "staged.example.com",
               "expected the failure to name the hostname it could not get an answer from"

        {:ok, context}
      end
    end
  end
end
