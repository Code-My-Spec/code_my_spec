defmodule CodeMySpecWeb.BddRulesController do
  use CodeMySpecWeb, :controller

  alias CodeMySpec.BddRules

  action_fallback CodeMySpecWeb.FallbackController

  def list_for_story(conn, %{"story_id" => story_id}) do
    scope = conn.assigns.current_scope
    rules = BddRules.list_rules_for_story(scope, story_id)
    render(conn, :index, rules: rules)
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case BddRules.get_rule(scope, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      rule ->
        render(conn, :show, rule: rule)
    end
  end

  def create(conn, %{"rule" => attrs}) do
    scope = conn.assigns.current_scope
    story_id = attrs["story_id"]

    case BddRules.create_rule(scope, story_id, Map.delete(attrs, "story_id")) do
      {:ok, rule} ->
        conn |> put_status(:created) |> render(:show, rule: rule)

      {:error, :missing_active_scope} ->
        conn |> put_status(:unauthorized) |> json(%{error: "missing_active_scope"})

      {:error, :persona_linkage_required} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "persona_linkage_required"})

      {:error, :story_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "story_not_found"})

      {:error, :cross_account} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "rule" => attrs}) do
    scope = conn.assigns.current_scope

    with %{} = rule <- BddRules.get_rule(scope, id) || {:error, :not_found},
         {:ok, updated} <- BddRules.update_rule(scope, rule, attrs) do
      render(conn, :show, rule: updated)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, :cross_account} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "cross_account"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: changeset_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with %{} = rule <- BddRules.get_rule(scope, id) || {:error, :not_found},
         {:ok, deleted} <- BddRules.delete_rule(scope, rule) do
      render(conn, :show, rule: deleted)
    else
      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc ->
        String.replace(acc, "%{#{k}}", to_string(v))
      end)
    end)
  end
end
