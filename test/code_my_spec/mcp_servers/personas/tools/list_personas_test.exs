defmodule CodeMySpec.McpServers.Personas.Tools.ListPersonasTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.ListPersonas

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.UsersFixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)

    account = account_fixture()

    scope =
      full_scope_fixture()
      |> Map.put(:active_account, account)
      |> Map.put(:active_account_id, account.id)

    frame = %Frame{assigns: %{current_scope: scope, working_dir: scope.cwd}}

    {:ok, scope: scope, frame: frame, account_id: account.id}
  end

  describe "ListPersonas tool" do
    test "returns empty-state text when the account has no personas", %{frame: frame} do
      {:reply, response, ^frame} = ListPersonas.execute(%{}, frame)

      assert response.type == :tool
      assert response.isError == false

      text = response_text(response)
      assert text =~ "No personas in this account yet"
    end

    test "lists personas when present", %{frame: frame, account_id: account_id} do
      insert_persona(account_id, "founder", "Founder")
      insert_persona(account_id, "agency_pm", "Agency PM")

      {:reply, response, ^frame} = ListPersonas.execute(%{}, frame)

      text = response_text(response)
      assert text =~ "Personas in this account (2)"
      assert text =~ "Founder"
      assert text =~ "`founder`"
      assert text =~ "Agency PM"
      assert text =~ "`agency_pm`"
    end
  end

  # --- helpers ---

  defp insert_persona(account_id, slug, name) do
    {:ok, persona} =
      %CodeMySpec.Personas.Persona{}
      |> CodeMySpec.Personas.Persona.changeset(%{
        slug: slug,
        name: name,
        account_id: account_id
      })
      |> CodeMySpec.Repo.insert()

    persona
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end
end
