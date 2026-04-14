defmodule Membrane.Gemini.Events.Transcript do
  @moduledoc """
  Contains transcripts for audio data,
  either client input (`audio_origin: :client`),
  or model response (`audio_origin: :server`).
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
          text: String.t(),
          audio_origin: :client | :server
        }

  @enforce_keys [:text, :audio_origin]

  defstruct @enforce_keys
end
