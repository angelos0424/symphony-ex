defmodule SymphonyEx.Automation do
  @moduledoc """
  Runtime automation policy helpers.

  The automation config is intentionally service-name driven so repos can add or
  remove services without changing runtime code.
  """

  alias SymphonyEx.Domain.Issue

  @type mode :: :default | :full_auto | :night_worker
  @type resolved_mode :: :default | :full_auto
  @type window :: %{
          start: String.t(),
          end: String.t(),
          start_minute: non_neg_integer(),
          end_minute: non_neg_integer()
        }
  @type t :: keyword()

  @default [
    mode: :default,
    services: [],
    service_concurrency: %{},
    reviewbot: [
      actors: [],
      actors_set: MapSet.new()
    ],
    full_auto: [
      apply_review_feedback: false,
      auto_merge: false,
      promote_next_ready_to_todo: false,
      allow_no_checks: false,
      merge_method: :squash,
      ready_state_name: "Ready"
    ],
    night_worker: [
      timezone: "Etc/UTC",
      windows: [],
      mode_during_window: :full_auto,
      mode_outside_window: :default
    ]
  ]

  @doc "Returns the default automation config."
  @spec default_config() :: t()
  def default_config, do: @default

  @doc "Normalizes automation config after schema validation."
  @spec normalize(keyword()) :: keyword()
  def normalize(config) when is_list(config) do
    config = Keyword.merge(@default, config)
    services = normalize_services(Keyword.get(config, :services, []))

    service_concurrency =
      config
      |> Keyword.get(:service_concurrency, %{})
      |> normalize_service_concurrency()

    config
    |> Keyword.put(:mode, normalize_mode(Keyword.get(config, :mode, :default)))
    |> Keyword.put(:services, services)
    |> Keyword.put(:services_set, MapSet.new(services))
    |> Keyword.put(:service_concurrency, service_concurrency)
    |> Keyword.update(:reviewbot, @default[:reviewbot], &normalize_reviewbot/1)
    |> Keyword.update(:full_auto, @default[:full_auto], &normalize_full_auto/1)
    |> Keyword.update(:night_worker, @default[:night_worker], &normalize_night_worker/1)
  end

  @doc "Validates automation config semantics that depend on multiple keys."
  @spec validate!(keyword()) :: keyword()
  def validate!(config) when is_list(config) do
    services = Keyword.get(config, :services, [])
    duplicates = duplicates(services)

    cond do
      duplicates != [] ->
        raise ArgumentError,
              "automation.services contains duplicate service names: #{Enum.join(duplicates, ", ")}"

      Keyword.get(config, :mode, :default) == :night_worker and
          Keyword.get(config, :night_worker, []) |> Keyword.get(:windows, []) == [] ->
        raise ArgumentError,
              "automation.night_worker.windows must not be empty when mode is night-worker"

      true ->
        :ok
    end

    validate_service_concurrency!(config)
    validate_reviewbot!(Keyword.get(config, :reviewbot, []))
    validate_night_worker!(Keyword.get(config, :night_worker, []))
    config
  end

  @doc "Resolves the active runtime automation mode."
  @spec resolve_mode(keyword(), DateTime.t()) :: resolved_mode()
  def resolve_mode(config, now \\ DateTime.utc_now()) do
    case Keyword.get(config, :mode, :default) do
      :full_auto ->
        :full_auto

      :night_worker ->
        night_worker = Keyword.get(config, :night_worker, [])

        if in_any_window?(now, night_worker) do
          Keyword.get(night_worker, :mode_during_window, :full_auto)
        else
          Keyword.get(night_worker, :mode_outside_window, :default)
        end

      _other ->
        :default
    end
  end

  @doc "Returns configured/effective automation mode details for status/debug output."
  @spec mode_status(keyword(), DateTime.t()) :: map()
  def mode_status(config, now \\ DateTime.utc_now()) do
    configured_mode = Keyword.get(config, :mode, :default)
    effective_mode = resolve_mode(config, now)
    night_worker = Keyword.get(config, :night_worker, [])
    night_worker_active? = configured_mode == :night_worker

    %{
      configured_mode: configured_mode,
      effective_mode: effective_mode,
      night_worker: %{
        timezone: Keyword.get(night_worker, :timezone, "Etc/UTC"),
        active: night_worker_active?,
        in_window: night_worker_active? and in_any_window?(now, night_worker),
        mode_during_window: Keyword.get(night_worker, :mode_during_window, :full_auto),
        mode_outside_window: Keyword.get(night_worker, :mode_outside_window, :default),
        windows: Enum.map(Keyword.get(night_worker, :windows, []), &window_status/1)
      }
    }
  end

  @doc "Derives an issue service from configured service names."
  @spec issue_service(Issue.t(), keyword()) ::
          String.t() | nil | {:error, {:unknown_service, String.t()}}
  def issue_service(%Issue{} = issue, config) do
    services = Keyword.get(config, :services, [])
    configured = Keyword.get(config, :services_set, MapSet.new(services))

    explicit_services =
      issue.labels
      |> Enum.map(&normalize_service_label/1)
      |> Enum.reject(&is_nil/1)

    unknown = Enum.find(explicit_services, &(not MapSet.member?(configured, &1)))

    cond do
      services == [] ->
        nil

      unknown ->
        {:error, {:unknown_service, unknown}}

      service = Enum.find(explicit_services, &MapSet.member?(configured, &1)) ->
        service

      service = title_prefix_service(issue.title, configured) ->
        service

      true ->
        nil
    end
  end

  @spec normalize_mode(term()) :: mode() | resolved_mode()
  def normalize_mode(:default), do: :default
  def normalize_mode(:full_auto), do: :full_auto
  def normalize_mode(:full_auto_mode), do: :full_auto
  def normalize_mode(:night_worker), do: :night_worker
  def normalize_mode("default"), do: :default
  def normalize_mode("full-auto"), do: :full_auto
  def normalize_mode("full_auto"), do: :full_auto
  def normalize_mode("night-worker"), do: :night_worker
  def normalize_mode("night_worker"), do: :night_worker
  def normalize_mode(other), do: other

  defp normalize_services(services) do
    Enum.map(services, fn service ->
      service |> to_string() |> String.trim() |> String.downcase()
    end)
  end

  defp normalize_service_concurrency(value) when is_map(value) do
    Map.new(value, fn {service, limit} -> {normalize_service_name(service), limit} end)
  end

  defp normalize_service_concurrency(value) when is_list(value) do
    Map.new(value, fn {service, limit} -> {normalize_service_name(service), limit} end)
  end

  defp normalize_service_concurrency(_), do: %{}

  defp normalize_service_name(service),
    do: service |> to_string() |> String.trim() |> String.downcase()

  defp normalize_reviewbot(opts) when is_list(opts) do
    opts =
      cond do
        Keyword.keyword?(opts) -> Keyword.merge(@default[:reviewbot], opts)
        true -> Keyword.put(@default[:reviewbot], :actors, opts)
      end

    actors =
      opts
      |> Keyword.get(:actors, Keyword.get(opts, :actor_logins, Keyword.get(opts, :logins, [])))
      |> normalize_reviewbot_actors()

    opts
    |> Keyword.put(:actors, actors)
    |> Keyword.put(:actors_set, MapSet.new(actors))
  end

  defp normalize_reviewbot(%{} = opts) do
    opts
    |> Enum.flat_map(fn {key, value} ->
      case normalize_reviewbot_key(key) do
        nil -> []
        normalized_key -> [{normalized_key, value}]
      end
    end)
    |> normalize_reviewbot()
  end

  defp normalize_reviewbot(actor) when is_binary(actor), do: normalize_reviewbot([actor])
  defp normalize_reviewbot(_opts), do: @default[:reviewbot]

  defp normalize_full_auto(opts) when is_list(opts) do
    opts = Keyword.merge(@default[:full_auto], opts)

    opts
    |> Keyword.put(:merge_method, normalize_merge_method(Keyword.get(opts, :merge_method)))
    |> Keyword.put(
      :ready_state_name,
      opts |> Keyword.get(:ready_state_name, "Ready") |> to_string() |> String.trim()
    )
  end

  defp normalize_full_auto(%{} = opts), do: opts |> Enum.into([]) |> normalize_full_auto()
  defp normalize_full_auto(_opts), do: @default[:full_auto]

  defp normalize_merge_method(method) when method in [:merge, :squash, :rebase], do: method

  defp normalize_merge_method(method) when is_binary(method) do
    case method |> String.trim() |> String.downcase() do
      "merge" -> :merge
      "rebase" -> :rebase
      _other -> :squash
    end
  end

  defp normalize_merge_method(_method), do: :squash

  defp normalize_reviewbot_key(key) when key in [:actors, :actor_logins, :logins], do: key

  defp normalize_reviewbot_key(key) when is_binary(key) do
    case key |> String.trim() |> String.replace("-", "_") do
      "actors" -> :actors
      "actor_logins" -> :actor_logins
      "logins" -> :logins
      _other -> nil
    end
  end

  defp normalize_reviewbot_key(_key), do: nil

  defp normalize_reviewbot_actors(actors) when is_list(actors) do
    actors
    |> Enum.map(&normalize_actor_login/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_reviewbot_actors(actor), do: normalize_reviewbot_actors([actor])

  defp normalize_actor_login(actor) do
    actor
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace_suffix("[bot]", "")
  end

  defp normalize_night_worker(opts) do
    opts = Keyword.merge(@default[:night_worker], opts)

    opts
    |> Keyword.put(:mode_during_window, normalize_mode(Keyword.get(opts, :mode_during_window)))
    |> Keyword.put(:mode_outside_window, normalize_mode(Keyword.get(opts, :mode_outside_window)))
    |> Keyword.update(:windows, [], fn windows -> Enum.map(windows, &normalize_window/1) end)
  end

  defp validate_service_concurrency!(config) do
    services = Keyword.get(config, :services, []) |> MapSet.new()

    config
    |> Keyword.get(:service_concurrency, %{})
    |> Enum.each(fn {service, limit} ->
      cond do
        not MapSet.member?(services, service) ->
          raise ArgumentError,
                "automation.service_concurrency contains service #{inspect(service)} not present in automation.services"

        not (is_integer(limit) and limit > 0) ->
          raise ArgumentError,
                "automation.service_concurrency.#{service} must be a positive integer"

        true ->
          :ok
      end
    end)
  end

  defp validate_reviewbot!(_opts), do: :ok

  defp validate_night_worker!(opts) do
    validate_timezone!(Keyword.get(opts, :timezone, "Etc/UTC"))
    Enum.each(Keyword.get(opts, :windows, []), &validate_window!/1)

    Enum.each([:mode_during_window, :mode_outside_window], fn key ->
      unless Keyword.get(opts, key) in [:default, :full_auto] do
        raise ArgumentError, "automation.night_worker.#{key} must be default or full-auto"
      end
    end)
  end

  defp validate_window!(window) when is_map(window) or is_list(window) do
    with start_minute when is_integer(start_minute) <- window_value(window, :start_minute),
         end_minute when is_integer(end_minute) <- window_value(window, :end_minute),
         false <- start_minute == end_minute do
      :ok
    else
      _ ->
        raise ArgumentError,
              "automation.night_worker.windows entries must use distinct HH:MM start/end values"
    end
  end

  defp validate_window!(_window) do
    raise ArgumentError, "automation.night_worker.windows entries must include start and end"
  end

  defp in_any_window?(now, opts) do
    local = local_datetime(now, Keyword.get(opts, :timezone, "Etc/UTC"))
    minute_of_day = local.hour * 60 + local.minute

    opts
    |> Keyword.get(:windows, [])
    |> Enum.any?(fn window ->
      start_minute = window_value(window, :start_minute)
      end_minute = window_value(window, :end_minute)
      in_window?(minute_of_day, start_minute, end_minute)
    end)
  end

  defp local_datetime(now, timezone) do
    case DateTime.shift_zone(now, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> now
    end
  end

  defp in_window?(minute, start_minute, end_minute) when start_minute < end_minute do
    minute >= start_minute and minute < end_minute
  end

  defp in_window?(minute, start_minute, end_minute) do
    minute >= start_minute or minute < end_minute
  end

  defp window_value(window, key) when is_map(window) do
    Map.get(window, key) || Map.get(window, to_string(key))
  end

  defp window_value(window, key) when is_list(window) do
    Keyword.get(window, key) || Keyword.get(window, String.to_atom(to_string(key)))
  end

  defp window_status(window) do
    %{
      start: window_value(window, :start),
      end: window_value(window, :end),
      start_minute: window_value(window, :start_minute),
      end_minute: window_value(window, :end_minute)
    }
  end

  defp normalize_window(window) when is_map(window) do
    start_minute = parse_time!(window_value(window, :start))
    end_minute = parse_time!(window_value(window, :end))

    window
    |> Map.put(:start_minute, start_minute)
    |> Map.put(:end_minute, end_minute)
  end

  defp normalize_window(window) when is_list(window) do
    start_minute = parse_time!(window_value(window, :start))
    end_minute = parse_time!(window_value(window, :end))

    window
    |> Keyword.put(:start_minute, start_minute)
    |> Keyword.put(:end_minute, end_minute)
  end

  defp normalize_window(_window) do
    raise ArgumentError, "automation.night_worker.windows entries must include start and end"
  end

  defp parse_time!(value) do
    case parse_time(value) do
      {:ok, minute} ->
        minute

      :error ->
        raise ArgumentError,
              "automation.night_worker.windows entries must use distinct HH:MM start/end values"
    end
  end

  defp validate_timezone!(timezone) when is_binary(timezone) do
    cond do
      String.contains?(timezone, ["..", "//"]) or String.starts_with?(timezone, "/") ->
        raise ArgumentError, "automation.night_worker.timezone must be a valid IANA timezone"

      File.regular?(Path.join("/usr/share/zoneinfo", timezone)) ->
        :ok

      true ->
        raise ArgumentError, "automation.night_worker.timezone must be a valid IANA timezone"
    end
  end

  defp validate_timezone!(_timezone) do
    raise ArgumentError, "automation.night_worker.timezone must be a valid IANA timezone"
  end

  defp parse_time(value) when is_binary(value) do
    case Regex.run(~r/^([01]?\d|2[0-3]):([0-5]\d)$/, value) do
      [_, hour, minute] -> {:ok, String.to_integer(hour) * 60 + String.to_integer(minute)}
      _ -> :error
    end
  end

  defp parse_time(_), do: :error

  defp normalize_service_label("service:" <> service), do: normalize_service_name(service)
  defp normalize_service_label("service/" <> service), do: normalize_service_name(service)
  defp normalize_service_label(_label), do: nil

  defp title_prefix_service(title, configured_services) when is_binary(title) do
    normalized_title = String.downcase(String.trim(title))

    Enum.find(configured_services, fn service ->
      String.starts_with?(normalized_title, [
        "[#{service}]",
        "#{service}:",
        "#{service} -",
        "#{service} "
      ])
    end)
  end

  defp title_prefix_service(_title, _configured_services), do: nil

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
