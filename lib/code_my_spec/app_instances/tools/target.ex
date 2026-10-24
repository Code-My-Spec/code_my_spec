defmodule CodeMySpec.AppInstances.Tools.Target do
  @moduledoc false

  alias CodeMySpec.AppInstances
  alias CodeMySpec.WorkingCopies

  @doc "Resolve the caller's working copy to its default app instance."
  def own_default(scope, context, requested_id \\ nil)

  def own_default(scope, _context, requested_id) when is_binary(requested_id) do
    copy_id = scope.active_working_copy_id

    case fetch_instance(scope, requested_id) do
      {:ok, %{working_copy_id: ^copy_id} = instance} when is_binary(copy_id) -> {:ok, instance}
      _ -> {:error, :instance_not_owned}
    end
  end

  def own_default(scope, _context, nil) when is_binary(scope.active_working_copy_id) do
    copy_id = scope.active_working_copy_id

    with {:ok, copy} <- WorkingCopies.fetch(copy_id) do
      AppInstances.ensure_default(scope, copy)
    end
  end

  def own_default(_scope, _context, _requested_id), do: {:error, :missing_active_working_copy}

  defp fetch_instance(scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case AppInstances.get(scope, id) do
          nil -> {:error, :not_found}
          instance -> {:ok, instance}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
