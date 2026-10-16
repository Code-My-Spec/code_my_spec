defmodule CodeMySpec.Files.ComponentRenames do
  @moduledoc false

  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Files.LiveCopies

  # Only the copy whose code speaks for the project can rename its shared
  # components. Match complete manifests, not just changed paths: duplicate
  # bodies anywhere in either snapshot make the evidence ambiguous.
  def reconcile(scope, observations) do
    if scope.active_working_copy_id in LiveCopies.speaking_ids(scope.active_project_id) do
      previous = Files.list_files(scope)
      old_groups = group(previous)
      new_groups = group(observations)
      old_names = names(previous)
      new_names = names(observations)

      Enum.each(old_groups, fn {fingerprint, old_files} ->
        reconcile_pair(
          scope,
          old_files,
          Map.get(new_groups, fingerprint, []),
          old_names,
          new_names
        )
      end)
    end

    :ok
  end

  defp reconcile_pair(scope, [old], [new], old_names, new_names) do
    old_name = data(old)["module_name"]
    new_name = data(new)["module_name"]

    if is_binary(old_name) and is_binary(new_name) and old_name != new_name and
         not MapSet.member?(new_names, old_name) and not MapSet.member?(old_names, new_name) do
      carry_identity(scope, old_name, new_name)
    end
  end

  defp reconcile_pair(_scope, _old, _new, _old_names, _new_names), do: :ok

  defp carry_identity(scope, old_name, new_name) do
    # An existing destination is a historical conflict, not permission to
    # merge or delete records. Leave it for explicit reconciliation.
    with nil <- Components.get_component_by_module_name(scope, new_name),
         %{} = component <- Components.get_component_by_module_name(scope, old_name) do
      {:ok, _updated} = Components.update_component(scope, component, %{module_name: new_name})
    end
  end

  defp group(files) do
    files
    |> Enum.filter(&implementation?/1)
    |> Enum.filter(&is_binary(data(&1)["rename_fingerprint"]))
    |> Enum.group_by(&data(&1)["rename_fingerprint"])
  end

  defp names(files) do
    files
    |> Enum.filter(&implementation?/1)
    |> MapSet.new(&data(&1)["module_name"])
  end

  defp implementation?(file), do: Map.get(file, :role) == :implementation
  defp data(%{validation_errors: %{"data" => data}}) when is_map(data), do: data
  defp data(_file), do: %{}
end
