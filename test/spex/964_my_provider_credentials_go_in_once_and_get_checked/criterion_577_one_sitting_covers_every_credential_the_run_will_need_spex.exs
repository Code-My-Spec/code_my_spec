defmodule CodeMySpecSpex.Story964.Criterion7981Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7981 — One sitting covers every credential the run will need.

  Credential intake asks for everything the chosen options require in
  one place, and no later step stops to ask for another. Sam pastes and
  walks away; the run does not interrupt him halfway through to collect
  something it could have asked for up front.

  Retargeted onto the console (provisioning-console-step6, unmerged):
  `all_setup_options/1` drove the old page's `setup-options-form`/
  `toggle_options` event, which `ConsoleLive` has not ported — there is no
  console UI for choosing setup options. Dropped rather than worked around:
  `Provisioning.setup_options/1` already returns every available option for
  a project whose `setup_options` is `nil` (`setup_active_project`'s own
  fixture never sets it), so a freshly created project already has every
  option on — the same state `all_setup_options/1` would have submitted back.
  "Every option is genuinely on" is still true, just by construction instead
  of by an explicit (and currently unreachable) toggle.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "One sitting covers every credential the run will need", criterion: 577 do
    scenario "every credential the chosen options need is asked for at once" do
      when_ "he opens credential entry", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        html = render(view)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "he is asked for every credential those options require", context do
        fields =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='credential-field']")

        # Anchor: intake rendered fields at all, so the per-credential
        # assertions below mean something.
        assert fields != [], "expected credential entry to render fields"

        asked =
          fields
          |> Enum.map(&(Floki.attribute(&1, "data-credential") |> List.first()))
          |> MapSet.new()

        # Prefixes, because the S3 pair is two fields — `hetzner_s3_access_key_id`
        # and `hetzner_s3_secret_access_key` — and the criterion is that the
        # pair is asked for, not that it arrives as one field.
        for credential <- ["hetzner_api_token", "hetzner_s3", "cloudflare_token", "resend"] do
          assert Enum.any?(asked, &String.starts_with?(&1 || "", credential)),
                 "expected intake to ask for #{credential}, got #{inspect(MapSet.to_list(asked))}"
        end

        {:ok, context}
      end

      then_ "the whole set is collected in one place", context do
        # One form, submitted once — not a wizard that returns for more
        # later. The presence of a single intake form carrying every
        # field is the observable form of "one sitting".
        assert has_element?(context.view, "[data-test='credentials-form']"),
               "expected a single credential intake form"

        {:ok, context}
      end
    end
  end
end
