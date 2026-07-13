defmodule CodeMySpecWeb.WidgetUsersJSON do
  alias CodeMySpec.ExternalUsers.ExternalUser

  def show(%{external_user: external_user}) do
    %{data: data(external_user)}
  end

  defp data(%ExternalUser{} = external_user) do
    %{
      id: external_user.id,
      external_id: external_user.external_id,
      email: external_user.email,
      name: external_user.name,
      metadata: external_user.metadata,
      project_id: external_user.project_id,
      inserted_at: external_user.inserted_at,
      updated_at: external_user.updated_at
    }
  end
end
