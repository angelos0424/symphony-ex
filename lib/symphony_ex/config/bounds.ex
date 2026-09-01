defmodule SymphonyEx.Config.Bounds do
  @moduledoc """
  Shared safety bounds for runtime orchestrator settings.
  """

  @bounds %{
    poll_interval_ms: %{min: 1, max: 86_400_000},
    max_concurrent: %{min: 1, max: 32},
    max_retries: %{min: 0, max: 20},
    backoff_base_ms: %{min: 1, max: 86_400_000}
  }

  @spec bounds() :: %{
          poll_interval_ms: %{min: 1, max: 86_400_000},
          max_concurrent: %{min: 1, max: 32},
          max_retries: %{min: 0, max: 20},
          backoff_base_ms: %{min: 1, max: 86_400_000}
        }
  def bounds, do: @bounds
end
