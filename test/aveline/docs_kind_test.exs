defmodule Aveline.DocsKindTest do
  use Aveline.DataCase, async: false

  alias Aveline.Docs
  alias Aveline.Docs.Doc
  alias Aveline.Fixtures

  setup do
    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    %{user: user, ws: ws}
  end

  defp create_attrs(ws, user, extra) do
    Map.merge(
      %{
        workspace_id: ws.id,
        owner_id: user.id,
        actor_user_id: user.id,
        actor_type: "agent",
        title: "Kind test",
        blocks: []
      },
      extra
    )
  end

  describe "changeset" do
    test "accepts both kinds and rejects everything else", %{user: user, ws: ws} do
      for kind <- Doc.kinds() do
        cs =
          Doc.changeset(%Doc{}, %{
            base_doc_id: Ecto.UUID.generate(),
            version_number: 1,
            workspace_id: ws.id,
            slug: "kind-#{kind}",
            title: "Kind #{kind}",
            owner_id: user.id,
            actor_user_id: user.id,
            actor_type: "agent",
            kind: kind
          })

        assert cs.valid?
      end

      cs =
        Doc.changeset(%Doc{}, %{
          base_doc_id: Ecto.UUID.generate(),
          version_number: 1,
          workspace_id: ws.id,
          slug: "kind-bad",
          title: "Kind bad",
          owner_id: user.id,
          actor_user_id: user.id,
          actor_type: "agent",
          kind: "spreadsheet"
        })

      refute cs.valid?
      assert %{kind: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "create_doc" do
    test "defaults to doc", %{user: user, ws: ws} do
      {:ok, doc} = Docs.create_doc(create_attrs(ws, user, %{}))
      assert doc.kind == "doc"
    end

    test "accepts notebook", %{user: user, ws: ws} do
      {:ok, doc} = Docs.create_doc(create_attrs(ws, user, %{kind: "notebook"}))
      assert doc.kind == "notebook"
    end

    test "rejects an unknown kind", %{user: user, ws: ws} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Docs.create_doc(create_attrs(ws, user, %{kind: "spreadsheet"}))

      assert %{kind: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "kind across versions" do
    test "carries across apply_ops and rejects kind in update_attrs", %{user: user, ws: ws} do
      {:ok, v1} = Docs.create_doc(create_attrs(ws, user, %{kind: "notebook"}))

      ops = [
        %{
          "op" => "append_block",
          "block" => %{"type" => "paragraph", "content" => [%{"text" => "more"}]}
        }
      ]

      # A kind smuggled into update_attrs fails loudly — never a silent
      # keep-the-old-kind success.
      assert {:error, message} =
               Docs.apply_ops(
                 v1,
                 ops,
                 %{actor_user_id: user.id, actor_type: "agent", kind: "doc"},
                 dispositions: []
               )

      assert message =~ "immutable"

      {:ok, v2} =
        Docs.apply_ops(v1, ops, %{actor_user_id: user.id, actor_type: "agent"}, dispositions: [])

      assert v2.version_number == 2
      assert v2.kind == "notebook"

      # Every version row carries the creation kind.
      kinds = Docs.list_versions(v1.base_doc_id) |> Enum.map(& &1.kind)
      assert kinds == ["notebook", "notebook"]
    end

    test "plain docs stay plain across edits", %{user: user, ws: ws} do
      {:ok, v1} = Docs.create_doc(create_attrs(ws, user, %{}))

      ops = [
        %{
          "op" => "append_block",
          "block" => %{"type" => "paragraph", "content" => [%{"text" => "more"}]}
        }
      ]

      {:ok, v2} =
        Docs.apply_ops(v1, ops, %{actor_user_id: user.id, actor_type: "agent"}, dispositions: [])

      assert v2.kind == "doc"
    end
  end
end
