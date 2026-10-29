defmodule CodeMySpec.PromotionQueue.FlakeReports do
  @moduledoc "Records confirmed promotion gate flakes as accepted issues."

  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue
  alias CodeMySpec.PromotionQueue.Entry
  alias CodeMySpec.Users.Scope

  @spec record_landed(Scope.t(), Entry.t(), [map()]) :: :ok
  def record_landed(%Scope{} = scope, %Entry{} = entry, confirmations)
      when is_list(confirmations) do
    copy_scope = %{scope | active_working_copy_id: entry.working_copy_id}
    Enum.each(confirmations, &record(copy_scope, entry.working_copy_id, &1))
  end

  defp record(scope, copy_id, %{source: source, file: file, name: name} = confirmation)
       when is_binary(source) and is_binary(file) and is_binary(name) do
    title = "Flaky test: #{source}: #{file}: #{name}"
    evidence = evidence(confirmation)

    case Enum.find(Issues.list_issues(scope), &open_flake?(&1, title)) do
      %Issue{} = issue -> update(issue, scope, copy_id, evidence, confirmation.rerun_id)
      nil -> create(scope, copy_id, title, file, evidence)
    end
  end

  defp open_flake?(%Issue{title: title, source: "promotion_flake", status: status}, title)
       when status in [:incoming, :accepted], do: true

  defp open_flake?(_issue, _title), do: false

  defp create(scope, copy_id, title, file, evidence) do
    {:ok, issue} =
      Issues.create_issue(scope, %{
        title: title,
        description:
          "Confirmed promotion gate flake. Fix the test before promoting again.\n\n" <> evidence,
        severity: :medium,
        scope: :app,
        status: :accepted,
        source: "promotion_flake",
        source_path: file
      })

    {:ok, _assigned} = Issues.set_assigned_working_copy(scope, issue, copy_id)
    :ok
  end

  defp update(%Issue{} = issue, scope, copy_id, evidence, rerun_id) do
    marker = "rerun #{rerun_id};"

    issue =
      if String.contains?(issue.description, marker) do
        issue
      else
        {:ok, updated} =
          Issues.update_issue(scope, issue, %{
            description: issue.description <> "\n\n" <> evidence
          })

        updated
      end

    case issue.assigned_working_copy_id do
      ^copy_id ->
        :ok

      _ ->
        {:ok, _assigned} = Issues.set_assigned_working_copy(scope, issue, copy_id)
        :ok
    end
  end

  defp evidence(%{
         source: source,
         file: file,
         name: name,
         message: message,
         gate_run_id: gate,
         rerun_id: rerun,
         commit: commit
       }) do
    "Gate run #{gate}; rerun #{rerun}; commit #{commit}; source #{source}; test #{file}: #{name}; failure: #{message}"
  end
end
