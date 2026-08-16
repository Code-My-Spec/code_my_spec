defmodule CodeMySpecSpex.Story972.Criterion8038Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8038 — Content that does not verify is left unserved.

  A published file that arrives at the site but fails verification is not
  served, and visitors keep seeing the previously good version. Serving
  unverified content would mean a corrupted or truncated publish silently
  replacing a working page.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_configured

  spex "Content that does not verify is left unserved" do
    scenario "a failing verification leaves the previous version serving" do
      given_ "a good version of the post is already live", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\ntype: blog\n---\n\nGood version.\n"
          )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Against the fleet, not a recording: the claim is that something good
        # was really being served before the failing publish, and a cassette
        # answers that from a file whatever the code did. The step's run button
        # is what records the proof — the publish button reports a result but
        # leaves no resource for the page to keep.
        before =
          view
          |> element("[data-test='setup-step'][data-step='content'] [data-test='run-step']")
          |> render_click()

        # Anchor: something good was serving before the bad publish.
        assert before =~ ~r/data-test="content-render-check"[^>]*data-status="200"/,
               "expected a good version to be live before the failing publish"

        {:ok, context |> Map.put(:view, view) |> Map.put(:served_before, served_version(before))}
      end

      when_ "a published file arrives but does not verify", context do
        # A real failure, not a recorded one: the objects upload and the
        # trigger lands as before, and the address the post should be served
        # at answers without serving it. That is what "arrives but does not
        # verify" is — the file is in the bucket and the site is up, and the
        # post is not there.
        site_serves_nothing(context)

        # One attempt. The render check retries, because the trigger is async
        # and a single fetch races it — but this site will never serve the
        # post, so waiting is time spent proving something already known.
        previous = Application.get_env(:code_my_spec, :provisioning_step_opts, [])

        Application.put_env(
          :code_my_spec,
          :provisioning_step_opts,
          Keyword.put(previous, :render_attempts, 1)
        )

        on_exit(fn ->
          Application.put_env(:code_my_spec, :provisioning_step_opts, previous)
        end)

        html =
          context.view
          |> element("[data-test='setup-step'][data-step='content'] [data-test='run-step']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is not served to visitors", context do
        parsed = Floki.parse_document!(context.html)

        verification =
          parsed |> Floki.find("[data-test='content-verification']")

        assert verification != [],
               "expected the verification result to be recorded. " <> diagnose(context.html)

        state = verification |> Floki.attribute("data-state") |> List.first()

        # `not_rendered` is the pipeline's own name for content that was
        # published and then did not come back from the site — the state this
        # criterion is about. "failed" was a guess at its vocabulary.
        assert state in ["not_rendered", "failed"],
               "expected verification to have failed, got #{inspect(state)}"

        served = verification |> Floki.attribute("data-served") |> List.first()

        assert served == "false",
               "expected unverified content not to be served, got #{inspect(served)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "the previously good version is still what they see", context do
        assert served_version(context.html) == context.served_before,
               "expected the live version to be unchanged by a failed publish:\n  before: #{inspect(context.served_before)}\n  after:  #{inspect(served_version(context.html))}"

        {:ok, context}
      end
    end
  end

  # What the content step reported, for when the verification span is missing
  # and the interesting question is what it did instead.
  defp diagnose(html) do
    step =
      html
      |> Floki.parse_document!()
      |> Floki.find("[data-test='setup-step'][data-step='content']")

    state = step |> Floki.attribute("data-state") |> List.first()
    detail = step |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 300)

    "content step state=#{inspect(state)} detail=#{inspect(detail)}"
  end

  defp served_version(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='content-served-version']")
    |> Floki.attribute("data-version")
    |> List.first()
  end
end
