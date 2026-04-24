defmodule CodeMySpec.McpServers.Personas.Tools.GetPersonaTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.GetPersona

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

  describe "GetPersona tool" do
    test "fetches by slug", %{frame: frame, account_id: account_id} do
      persona = insert_persona(account_id, "founder", "Founder", "Solo founder")

      {:reply, response, ^frame} = GetPersona.execute(%{slug: "founder"}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Founder"
      assert text =~ "founder"
      assert text =~ persona.id
    end

    test "fetches by id when slug not given", %{frame: frame, account_id: account_id} do
      persona = insert_persona(account_id, "agency_pm", "Agency PM", nil)

      {:reply, response, ^frame} = GetPersona.execute(%{id: persona.id}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Agency PM"
      assert text =~ "agency_pm"
    end

    test "slug wins when both slug and id are given",
         %{frame: frame, account_id: account_id} do
      founder = insert_persona(account_id, "founder", "Founder", nil)
      _agency_pm = insert_persona(account_id, "agency_pm", "Agency PM", nil)

      {:reply, response, ^frame} =
        GetPersona.execute(%{slug: "founder", id: Ecto.UUID.generate()}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "Founder"
      assert text =~ founder.id
    end

    test "returns error when neither slug nor id is provided", %{frame: frame} do
      {:reply, response, ^frame} = GetPersona.execute(%{}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/provide either.*slug.*or.*id/i
    end

    test "returns not_found when slug doesn't exist in the account", %{frame: frame} do
      {:reply, response, ^frame} = GetPersona.execute(%{slug: "nobody"}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/not found/i
    end

    test "returns not_found when id doesn't exist in the account", %{frame: frame} do
      {:reply, response, ^frame} =
        GetPersona.execute(%{id: Ecto.UUID.generate()}, frame)

      assert response.isError == true
      text = error_text(response)
      assert text =~ ~r/not found/i
    end
  end

  # --- helpers ---

  defp insert_persona(account_id, slug, name, headline) do
    {:ok, persona} =
      %CodeMySpec.Personas.Persona{}
      |> CodeMySpec.Personas.Persona.changeset(%{
        slug: slug,
        name: name,
        headline: headline,
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

  defp error_text(response) do
    # Errors may land in `content` (text variant) or a top-level message — flatten both.
    (response_text(response) || "") <> "\n" <> inspect(response)
  end
end
