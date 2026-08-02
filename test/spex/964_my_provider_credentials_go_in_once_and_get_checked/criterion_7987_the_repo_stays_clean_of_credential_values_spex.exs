defmodule CodeMySpecSpex.Story964.Criterion7987Spex do
  @moduledoc """
  Story 964 — My provider credentials go in once and get checked
  Criterion 7987 — The repo stays clean of credential values.

  Entering credentials writes nothing into the project's working tree.
  They live in the project's encrypted store, so a `git push` after
  intake cannot leak them and an agent reading the repo cannot find
  them.

  The `then_` reads the in-memory project filesystem — sanctioned by the
  boundary rules precisely because "no credential value on disk" *is*
  the user-visible effect here.

  Surface: `CodeMySpecWeb.CredentialsLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @secret_value "s3cr3t-value-that-must-not-land-on-disk"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The repo stays clean of credential values" do
    scenario "no credential value appears anywhere in the working tree" do
      given_ "Sam is on credential entry", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he enters all his credentials", context do
        context.view
        # The pasted credentials — the ones with a field. Cloudflare and
        # Resend are connected on the account by OAuth, so there is no value
        # to type and none that could reach the repo from here.
        |> form("[data-test='credentials-form']",
          credentials: %{
            hetzner_api_token: @secret_value,
            hetzner_s3_access_key_id: @secret_value,
            hetzner_s3_secret_access_key: @secret_value
          }
        )
        |> render_submit()

        {:ok, context}
      end

      then_ "none of the values appears in the repo", context do
        {:ok, entries} = Environments.list_directory(context.environment, ".")

        offenders =
          entries
          |> Enum.filter(fn path ->
            case Environments.read_file(context.environment, path) do
              {:ok, contents} -> String.contains?(contents, @secret_value)
              _ -> false
            end
          end)

        assert offenders == [],
               "expected no credential value in the working tree, found in: #{inspect(offenders)}"

        {:ok, context}
      end

      then_ "the credentials are still usable by setup", context do
        # Anchor: proves the refute above is not passing because intake
        # silently dropped everything.
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        assert has_element?(
                 view,
                 "[data-test='credential-field'][data-credential='hetzner_api_token'][data-stored='true']"
               ),
               "expected the stored credential to be recorded even though its value is not on disk"

        {:ok, context}
      end
    end
  end
end
