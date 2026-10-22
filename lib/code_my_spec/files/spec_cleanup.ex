defmodule CodeMySpec.Files.SpecCleanup do
  @moduledoc """
  A spex outlives its criterion unless something removes it (issue 73e302aa).

  A criterion's wording is never changed (story 1076): the only change that
  invalidates its spex is retiring it. A spex names its criterion by number
  (`Files.SpecBinding`), so a retired or unknown number covers nothing, and the
  file stays on disk to be deleted by hand: 21 legacy story-561 spex were.

  This removes them:

    * `for_retired/2` when a criterion is retired: every spex file naming its
      number;
    * `sweep_orphans/1`: any spex whose number is not a live criterion (unknown
      or retired), whatever retired it and whenever.

  Only on the caller's own working copy. A spex is a tracked file: deleted on
  disk everywhere at once, it left every checkout, main's included, with the
  same uncommitted deletions, and every certification refused on them. Deleted
  here it is the caller's change to commit, and it reaches the other copies
  when they take main.

  Each file is deleted through the copy's environment,
  and the answer says what happened to each: `:deleted`, or `{:pending, why}`
  when the copy cannot be reached or the deletion failed. A pending file stays
  recorded, still covering nothing, and a later sweep tries it again; coverage
  is never claimed for it. Nothing here is inferred from filenames or from
  obsolete ids: only the number the file's `spex` call names.
  """

  import Ecto.Query

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.File
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  @type outcome :: :deleted | {:pending, term()}
  @type result :: %{
          path: String.t(),
          criterion_number: pos_integer(),
          working_copy_id: String.t() | nil,
          outcome: outcome()
        }

  @doc "Delete every spex naming the retired criterion's number."
  @spec for_retired(Scope.t(), pos_integer()) :: [result()]
  def for_retired(%Scope{} = scope, number) when is_integer(number) do
    scope |> spex_rows() |> Enum.filter(&(&1.criterion_number == number)) |> delete_all(scope)
  end

  @doc "Delete every spex whose number is not a live criterion."
  @spec sweep_orphans(Scope.t()) :: [result()]
  def sweep_orphans(%Scope{} = scope) do
    rows = spex_rows(scope)
    numbers = rows |> Enum.map(& &1.criterion_number) |> Enum.uniq()

    live =
      scope
      |> AcceptanceCriteria.list_criteria_by_number(numbers)
      |> Enum.filter(&is_nil(&1.retired_at))
      |> MapSet.new(& &1.number)

    rows |> Enum.reject(&MapSet.member?(live, &1.criterion_number)) |> delete_all(scope)
  end

  @doc "The lines a tool reports for `results`: what was deleted, what is pending."
  @spec report([result()]) :: String.t()
  def report([]), do: "No spex file named it."

  def report(results) do
    Enum.map_join(results, "\n", fn
      %{outcome: :deleted} = r ->
        "Deleted spex #{r.path} (criterion #{r.criterion_number})."

      %{outcome: {:pending, why}} = r ->
        "Pending deletion: #{r.path} (criterion #{r.criterion_number}) — #{describe(why)}. " <>
          "It covers nothing and will be removed by the next sweep."
    end)
  end

  defp describe(:no_working_copy), do: "no working copy recorded for it"
  defp describe(reason) when is_atom(reason), do: "the working copy answered #{reason}"
  defp describe(reason), do: "the working copy could not delete it (#{inspect(reason)})"

  defp spex_rows(%Scope{active_project_id: project_id, active_working_copy_id: copy_id})
       when is_binary(project_id) and is_binary(copy_id) do
    Repo.all(
      from f in File,
        where:
          f.project_id == ^project_id and f.working_copy_id == ^copy_id and
            f.role == :bdd_spec and not is_nil(f.criterion_number),
        order_by: [asc: f.criterion_number, asc: f.path]
    )
  end

  defp spex_rows(_scope), do: []

  defp delete_all(rows, scope), do: Enum.map(rows, &delete_one(&1, scope))

  defp delete_one(%File{} = file, scope) do
    %{
      path: file.path,
      criterion_number: file.criterion_number,
      working_copy_id: file.working_copy_id,
      outcome: remove(file, scope)
    }
  end

  defp remove(%File{working_copy_id: nil}, _scope), do: {:pending, :no_working_copy}

  defp remove(%File{} = file, scope) do
    env = WorkingCopies.environment(%{scope | active_working_copy_id: file.working_copy_id})

    case Environments.delete_file(env, file.path) do
      result when result in [:ok, {:error, :enoent}] ->
        Repo.delete(file)
        :deleted

      {:error, reason} ->
        {:pending, reason}
    end
  end
end
