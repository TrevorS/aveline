defmodule Aveline.DocKindTest do
  @moduledoc """
  The `kind` column ("doc" | "notebook"): set once at creation, validated
  by changeset, and immutable across versions like pin_slot/orientation.
  """
  use Aveline.DataCase, async: false

  alias Aveline.Docs
  alias Aveline.Docs.Doc
  alias Aveline.Fixtures

  setup do
    user = Fixtures.user_fixture()
    ws = Fixtures.workspace_fixture(user)
    %{user: user, ws: ws}
  end

  describe "changeset" do
    test "accepts the two known kinds" do
      for kind <- ~w(doc notebook) do
        cs = Doc.changeset(%Doc{}, base_attrs(%{kind: kind}))
        assert cs.valid?
        assert Ecto.Changeset.get_field(cs, :kind) == kind
      end
    end

    test "rejects an unknown kind" do
      cs = Doc.changeset(%Doc{}, base_attrs(%{kind: "spreadsheet"}))
      refute cs.valid?
      assert %{kind: _} = errors_on(cs)
    end
  end

  describe "create_doc" do
    test "defaults to doc when kind is omitted", %{user: user, ws: ws} do
      {:ok, doc} =
        Docs.create_doc(%{
          workspace_id: ws.id,
          owner_id: user.id,
          actor_user_id: user.id,
          actor_type: "human",
          title: "Plain doc",
          blocks: []
        })

      assert doc.kind == "doc"
    end

    test "creates a notebook when kind: notebook", %{user: user, ws: ws} do
      {:ok, nb} =
        Docs.create_doc(%{
          workspace_id: ws.id,
          owner_id: user.id,
          actor_user_id: user.id,
          actor_type: "agent",
          kind: "notebook",
          title: "Analysis notebook",
          blocks: []
        })

      assert nb.kind == "notebook"
    end
  end

  test "kind is immutable across apply_ops — even if a kind field is sent", %{
    user: user,
    ws: ws
  } do
    {:ok, nb} =
      Docs.create_doc(%{
        workspace_id: ws.id,
        owner_id: user.id,
        actor_user_id: user.id,
        actor_type: "agent",
        kind: "notebook",
        title: "Notebook",
        blocks: []
      })

    ops = [
      %{
        "op" => "append_block",
        "block" => %{"type" => "paragraph", "content" => [%{"text" => "hi"}]}
      }
    ]

    # A stray kind in update_attrs must not downgrade the notebook.
    {:ok, v2} =
      Docs.apply_ops(nb, ops, %{actor_user_id: user.id, actor_type: "agent", kind: "doc"}, dispositions: [])

    assert v2.version_number == 2
    assert v2.kind == "notebook"

    # Every version row carries the creation kind.
    kinds = nb.base_doc_id |> Docs.list_versions() |> Enum.map(& &1.kind) |> Enum.uniq()
    assert kinds == ["notebook"]
  end

  defp base_attrs(overrides) do
    Map.merge(
      %{
        base_doc_id: Ecto.UUID.generate(),
        version_number: 1,
        workspace_id: Ecto.UUID.generate(),
        slug: "some-doc",
        title: "Some doc",
        owner_id: Ecto.UUID.generate(),
        actor_user_id: Ecto.UUID.generate(),
        actor_type: "human"
      },
      overrides
    )
  end
end
