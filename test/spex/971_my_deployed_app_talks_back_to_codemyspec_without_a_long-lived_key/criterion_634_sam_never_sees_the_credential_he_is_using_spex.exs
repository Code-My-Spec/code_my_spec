defmodule CodeMySpecSpex.Story971.Criterion8022Spex do
  @moduledoc """
  Story 971 — My deployed app talks back to CodeMySpec without a long-lived key
  Criterion 8022 — Sam never sees the credential he is using.

  After setup finishes, the environment authenticates to CodeMySpec and Sam
  never copied a value between two systems to make it so. Today the
  `deploy_key` lives in four config files that somebody pasted it into; the
  criterion is that the credential is placed, not transcribed.

  Retargeted onto the console (provisioning-console-step6, unmerged):
  `callback_credential` is one of the `servers` resource group's steps
  (see `ConsoleLive.ResourceGroups`), so it runs on
  `/console/resources/servers`'s Config tab — `prod` is the default
  environment there, same as every other per-environment step criterion
  603's moduledoc describes retargeting. `run_step_interaction/3` is
  coupled to the old page, so this uses `run_console_step/2` instead —
  followed by its own `render/1`, since `run_step`'s handler only
  reassigns `@plan` when the step's PubSub broadcast is handled, not
  inside the `handle_event` call `render_click/1` returns from.

  Surface: `CodeMySpecWeb.ConsoleLive` for the placement, HTTP for the
  proof it works.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ExecutionContexts

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # A real directory: this criterion reads the working tree, looking for the
  # credential in what setup wrote. A memory filesystem holding nothing finds
  # no leaked credential for the same reason it finds no files, and
  # `list_directory/2` on an empty store answers `{:error, :enoent}`.
  setup :real_working_directory
  setup :fake_providers
  setup :fake_providers

  spex "Sam never sees the credential he is using", criterion: 634 do
    scenario "setup places the credential and the environment authenticates with it" do
      given_ "Sam is on the setup status page", context do
        app_holds_refresh_secret(context.scope)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "setup finishes placing the callback credential", context do
        run_console_step(context.view, :callback_credential)

        # Not `run_console_step/2`'s own return: `run_step`'s handler
        # reassigns `@plan` only when the step's PubSub broadcast arrives
        # and `refresh/1` runs in `handle_info`, not inside its own
        # `handle_event` return — so the click's own render can still show
        # the pre-run state even though the step already completed.
        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the environment can authenticate", context do
        assert context.html =~ ~r/data-step="callback_credential"[^>]*data-state="done"/,
               "expected the credential placement step to complete"

        placement =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='callback-credential']")

        # Anchor: a credential was placed somewhere identifiable.
        assert placement != [], "expected setup to record where it placed the credential"

        destination = placement |> Floki.attribute("data-placed-in") |> List.first()

        assert destination == "encrypted_env",
               "expected the credential to be placed into the environment's encrypted env, got #{inspect(destination)}"

        {:ok, Map.put(context, :placement, placement)}
      end

      then_ "Sam never copied a value between two systems", context do
        manual = context.placement |> Floki.attribute("data-manual-copy") |> List.first()

        assert manual == "false",
               "expected no manual copy step, got #{inspect(manual)}"

        {:ok, context}
      end

      then_ "the value is not left sitting in plaintext config", context do
        {:ok, entries} = ExecutionContexts.list_directory(context.execution_context, ".")

        plaintext_configs =
          Enum.filter(entries, fn path ->
            Path.extname(path) in [".exs", ".env"] and
              carries_credential?(ExecutionContexts.read_file(context.execution_context, path))
          end)

        assert plaintext_configs == [],
               "expected no plaintext config carrying the credential, found: #{inspect(plaintext_configs)}"

        {:ok, context}
      end
    end
  end

  # Function heads rather than a `case`, and one read rather than two: the
  # previous form read every file twice — once to `match?` it and once to
  # search it — which is the shape a `case` inside a filter tends to take.
  defp carries_credential?({:ok, body}) when is_binary(body),
    do: body =~ ~r/deploy_key|refresh_secret/

  defp carries_credential?(_), do: false
end
