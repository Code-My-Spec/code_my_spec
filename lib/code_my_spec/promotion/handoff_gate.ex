defmodule CodeMySpec.Promotion.HandoffGate do
  @moduledoc "Artifact preservation must be completed and acknowledged before its copy promotes."
  import Ecto.Query
  alias CodeMySpec.Repo

  def check(project_id, copy_id) do
    pending =
      Repo.exists?(
        from(h in "completion_handoffs",
          where:
            h.project_id == type(^project_id, :binary_id) and
              h.working_copy_id == type(^copy_id, :binary_id) and h.status != "acknowledged"
        )
      )

    case pending do
      false ->
        :ok

      true ->
        {:error,
         %{
           reason:
             "Artifact preservation on this copy still requires completion and main acknowledgement. Read completion_handoff; this is not a QA verdict.",
           working_copy: %{id: copy_id}
         }}
    end
  end
end
