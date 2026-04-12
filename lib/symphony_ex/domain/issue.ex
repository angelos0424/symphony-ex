defmodule SymphonyEx.Domain.Issue do
  @moduledoc """
  Tracker-agnostic issue domain model.
  """

  @type id :: String.t()

  @type t :: %__MODULE__{
          id: id(),
          identifier: String.t(),
          title: String.t(),
          description: String.t(),
          url: String.t(),
          state: String.t(),
          priority: non_neg_integer(),
          labels: [String.t()],
          assignees: [String.t()],
          conflict_hints: [String.t()],
          parent_id: String.t() | nil,
          children_ids: [String.t()]
        }

  @enforce_keys [:id, :identifier, :title, :description, :state]
  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :url,
    :state,
    :parent_id,
    priority: 0,
    labels: [],
    assignees: [],
    conflict_hints: [],
    children_ids: []
  ]
end
