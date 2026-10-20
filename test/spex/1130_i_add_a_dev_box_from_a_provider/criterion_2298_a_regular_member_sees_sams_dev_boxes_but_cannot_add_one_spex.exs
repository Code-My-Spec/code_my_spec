defmodule CodeMySpecSpex.Story1130.Criterion2298Spex do
  @moduledoc """
  Story 1130 — I add a dev box from a provider.
  Criterion 2298 — A regular member sees Sam's dev boxes but cannot add one.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A member who is not an owner or admin cannot add", criterion: 2298 do
    scenario "the member opens Dev boxes" do
      given_ "Sam's account has a dev box and a member who is not an owner or admin", context do
        {:ok, owner_live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(owner_live, "sams-box", "local")

        member = Fixtures.user_fixture()
        _membership = Fixtures.member_fixture(member, context.account, :member)
        member_scope = Fixtures.user_scope_fixture(member, context.account)
        Fixtures.select_active_account(member_scope, context.account.id)

        {:ok, Map.put(context, :member_conn, log_in_user(build_conn(), member))}
      end

      when_ "the member opens DevOps > Dev boxes", context do
        {:ok, live, _html} = open_dev_boxes(context.member_conn, context.project)
        {:ok, Map.put(context, :live, live)}
      end

      then_ "they see the box", context do
        assert has_element?(context.live, "[data-test='dev-box'][data-box-name='sams-box']")
        {:ok, context}
      end

      then_ "there is no way for them to add one, and an add they send anyway is refused",
            context do
        refute has_element?(context.live, "[data-test='add-dev-box']")

        render_hook(context.live, "add_dev_box", %{
          "dev_box" => %{"name" => "sneaky", "provider" => "local"}
        })

        refute render(context.live) =~ "sneaky"

        {:ok, fresh, _html} = open_dev_boxes(context.member_conn, context.project)
        refute has_element?(fresh, "[data-test='dev-box'][data-box-name='sneaky']")
        {:ok, context}
      end
    end
  end
end
