defmodule CodeMySpecSpex.Story985.Criterion8178Spex do
  @moduledoc """
  Story 985 — My repository exists before anything needs to push
  Criterion 8178 — One repository, carrying the project's docs.

  A new project gets one repository, and its docs live inside it. Not two
  repositories, and not a submodule: `.code_my_spec/` is part of the working
  tree the harness reads, so a clone that lacks it is a project the harness
  cannot work on. Splitting the docs out is a deliberate later operation, not
  the default a new project is born with.

  Retargeted onto the console (provisioning-console-step6, unmerged):
  `ResourceDetail`'s Config tab carries the same per-step
  `provisioned-resource` listing `step_card` did, so the resource-detail
  page is what "one repository, recorded under its own step" means now.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Repository`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  # A modelled shell over the memory filesystem: the repository step's proof
  # is a `git push`, which is a subprocess rather than an API call.
  setup :fake_working_directory

  spex "One repository, carrying the project's docs", criterion: 748 do
    scenario "the step creates a single repository and records it as the remote" do
      given_ "Sam is on the setup status page with GitHub connected", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the repository step runs", context do
        run_console_step(context.view, :repository)

        html = render(context.view)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "exactly one repository is recorded", context do
        repos =
          context.html
          |> Floki.parse_document!()
          # Scoped to the step, same selector the old page's spex used —
          # there is no separate global panel here yet to disambiguate
          # against, but an unscoped count would also catch a resource from
          # another step in the same group if one ever carried kind
          # "repository" too.
          |> Floki.find(
            "[data-test='resource-step'][data-step='repository'] " <>
              "[data-test='provisioned-resource'][data-kind='repository']"
          )

        assert length(repos) == 1,
               "expected one repository, got #{length(repos)}"

        {:ok, Map.put(context, :repos, repos)}
      end

      then_ "no second repository is created for docs", context do
        refute context.html =~ ~r/data-kind="repository"[^>]*data-role="docs"/,
               "expected the docs to live inside the one repository, not in a second one"

        {:ok, context}
      end

      then_ "the project records that repository as its remote", context do
        remote =
          context.repos
          |> List.first()
          |> Floki.attribute("data-location")
          |> List.first()

        assert is_binary(remote) and remote != "",
               "expected the repository's location recorded so the harness has a remote to push to"

        {:ok, context}
      end
    end
  end
end
