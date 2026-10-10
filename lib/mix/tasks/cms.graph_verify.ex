defmodule Mix.Tasks.Cms.GraphVerify do
  @shortdoc "Check served graph behavior against a fresh computation"
  @moduledoc """
  Runs the same parity audit as the dev graph page and fails on disagreement.

      mix cms.graph_verify --project PROJECT_UUID
      mix cms.graph_verify --project PROJECT_UUID --working-copy COPY_UUID

  Without --working-copy this checks the project view. Run once for each
  checkout whose graph must be verified. The report is JSON and identifies the
  exact vantage and observation time. The command does not settle or repair
  rows first: doing so could hide the stale graph it is meant to detect.

  Agreement is with the fresh computation, not an independent proof that the
  shared requirement definitions are correct. Domain acceptance tests remain
  necessary. Run against a settled project; concurrent writes can produce a
  transient disagreement because the audit reads several database snapshots.
  """

  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Verification
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies.WorkingCopy

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [project: :string, working_copy: :string])

    if args != [] or invalid != [], do: Mix.raise("Invalid graph verification arguments")
    project_id = uuid!(opts[:project], "--project")
    copy_id = working_copy_id(opts[:working_copy])
    Mix.Task.run("app.start")
    validate_copy!(copy_id, project_id)

    report =
      Requirements.served_vs_recomputed(%Scope{
        active_project_id: project_id,
        active_working_copy_id: copy_id
      })

    clean? = Verification.clean?(report)

    report
    |> Map.merge(%{
      project_id: project_id,
      working_copy_id: copy_id,
      checked_at: DateTime.utc_now(),
      agrees: clean?
    })
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()

    unless clean?, do: exit({:shutdown, 1})
  end

  defp working_copy_id(nil), do: nil
  defp working_copy_id(value), do: uuid!(value, "--working-copy")

  defp uuid!(value, option) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> Mix.raise("#{option} requires a UUID")
    end
  end

  defp validate_copy!(nil, _project_id), do: :ok

  defp validate_copy!(id, project_id) do
    case Repo.get(WorkingCopy, id) do
      %WorkingCopy{project_id: ^project_id} -> :ok
      _ -> Mix.raise("--working-copy must belong to the selected project")
    end
  end
end
