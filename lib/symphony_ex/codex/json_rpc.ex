defmodule SymphonyEx.Codex.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 message encoding/decoding for app-server stdio communication.
  """

  @type request :: %{
          jsonrpc: String.t(),
          id: pos_integer(),
          method: String.t(),
          params: map()
        }

  @type response :: %{
          id: pos_integer() | nil,
          result: map() | nil,
          error: map() | nil
        }

  @type notification :: %{
          jsonrpc: String.t(),
          method: String.t(),
          params: map()
        }

  @spec encode_request(pos_integer(), String.t(), map()) :: String.t()
  def encode_request(id, method, params \\ %{}) do
    %{jsonrpc: "2.0", id: id, method: method, params: params}
    |> Jason.encode!()
  end

  @spec encode_notification(String.t(), map()) :: String.t()
  def encode_notification(method, params \\ %{}) do
    %{jsonrpc: "2.0", method: method, params: params}
    |> Jason.encode!()
  end

  @spec decode_line(String.t()) ::
          {:response, response()} | {:notification, notification()} | {:error, term()}
  def decode_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{"id" => _id} = msg} ->
        {:response, normalize_response(msg)}

      {:ok, %{"method" => _method} = msg} ->
        {:notification, normalize_notification(msg)}

      {:ok, other} ->
        {:notification, %{jsonrpc: "2.0", method: "unknown", params: other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec normalize_response(map()) :: response()
  defp normalize_response(msg) do
    %{
      id: msg["id"],
      result: msg["result"],
      error: msg["error"]
    }
  end

  @spec normalize_notification(map()) :: notification()
  defp normalize_notification(msg) do
    %{
      jsonrpc: "2.0",
      method: msg["method"] || "unknown",
      params: msg["params"] || %{}
    }
  end
end
