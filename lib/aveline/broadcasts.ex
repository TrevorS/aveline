defmodule Aveline.Broadcasts do
  @moduledoc """
  Central PubSub helper. Topics are keyed by stable identifiers
  (base_doc_id for docs, workspace_id for workspaces) so subscribers
  stay attached across edits.
  """

  alias Phoenix.PubSub

  @pubsub Aveline.PubSub

  def subscribe(topic) when is_binary(topic), do: PubSub.subscribe(@pubsub, topic)
  def unsubscribe(topic) when is_binary(topic), do: PubSub.unsubscribe(@pubsub, topic)

  def doc_topic(base_doc_id), do: "doc:" <> base_doc_id
  def doc_comments_topic(base_doc_id), do: "doc:" <> base_doc_id <> ":comments"
  def workspace_docs_topic(workspace_id), do: "workspace:" <> workspace_id <> ":docs"

  # Cell-run events carry a payload map (base_doc_id, block_id, run
  # summary) instead of a doc struct — same topics, keyed the same way.
  def publish_doc_event(event, %{base_doc_id: base, workspace_id: ws_id} = doc)
      when event in [
             :doc_created,
             :doc_updated,
             :doc_deleted,
             :doc_restored,
             :cell_run_started,
             :cell_run_finished
           ] do
    PubSub.broadcast(@pubsub, doc_topic(base), {event, doc})
    PubSub.broadcast(@pubsub, workspace_docs_topic(ws_id), {event, doc})
    :ok
  end
end
