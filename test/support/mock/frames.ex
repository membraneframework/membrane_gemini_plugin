defmodule GeminiMock.Frames do
  @moduledoc false
  # Wire-format (string-keyed, camelCase) Gemini Live API server frames.
  #
  # Single source of truth for server-message fixtures: `GeminiMock.Scenario.push/2`
  # JSON-encodes these onto the socket, and direct-injection tests convert them
  # with `to_server_message/1` — the same decode path (`ServerMessage.from_api/1`)
  # the production `Gemini.Live.Session` uses, so fixtures cannot drift from the
  # wire format.

  @output_audio_format %Membrane.RawAudio{
    sample_format: :s16le,
    channels: 1,
    sample_rate: 24_000
  }

  @output_mime_type "audio/pcm;rate=24000"

  @spec audio(binary()) :: map()
  def audio(pcm) when is_binary(pcm) do
    model_turn([
      %{"inlineData" => %{"mimeType" => @output_mime_type, "data" => Base.encode64(pcm)}}
    ])
  end

  @spec audio_of_ms(non_neg_integer()) :: map()
  def audio_of_ms(ms) do
    @output_audio_format
    |> Membrane.RawAudio.silence(Membrane.Time.milliseconds(ms))
    |> audio()
  end

  @spec thinking(String.t()) :: map()
  def thinking(text), do: model_turn([%{"thought" => true, "text" => text}])

  @spec model_turn([map()]) :: map()
  def model_turn(parts) do
    %{"serverContent" => %{"modelTurn" => %{"role" => "model", "parts" => parts}}}
  end

  @spec input_transcription(String.t()) :: map()
  def input_transcription(text),
    do: %{"serverContent" => %{"inputTranscription" => %{"text" => text}}}

  @spec output_transcription(String.t()) :: map()
  def output_transcription(text),
    do: %{"serverContent" => %{"outputTranscription" => %{"text" => text}}}

  @spec generation_complete() :: map()
  def generation_complete, do: %{"serverContent" => %{"generationComplete" => true}}

  @spec turn_complete(map()) :: map()
  def turn_complete(usage_metadata \\ %{"totalTokenCount" => 42}) do
    %{"serverContent" => %{"turnComplete" => true}, "usageMetadata" => usage_metadata}
  end

  @spec interrupted() :: map()
  def interrupted, do: %{"serverContent" => %{"interrupted" => true}}

  @spec usage_metadata(map()) :: map()
  def usage_metadata(usage_metadata \\ %{"totalTokenCount" => 42}) do
    %{"serverContent" => %{}, "usageMetadata" => usage_metadata}
  end

  @spec go_away(String.t()) :: map()
  def go_away(time_left \\ "10s"), do: %{"goAway" => %{"timeLeft" => time_left}}

  @spec resumption_update(String.t()) :: map()
  def resumption_update(handle),
    do: %{"sessionResumptionUpdate" => %{"newHandle" => handle, "resumable" => true}}

  @doc """
  Decodes a wire-format frame into the struct the session delivers to the
  endpoint via the `:on_message` callback. For direct-injection tests.
  """
  @spec to_server_message(map()) :: Gemini.Types.Live.ServerMessage.t()
  def to_server_message(frame), do: Gemini.Types.Live.ServerMessage.from_api(frame)
end
