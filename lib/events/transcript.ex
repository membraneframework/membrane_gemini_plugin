defmodule Membrane.Gemini.Events.Transcript do
  @moduledoc """
  Contains transcripts audio data, either client input or model response.
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
          text: String.t(),
          direction: :input | :output
        }

  @enforce_keys [:text, :direction]

  defstruct @enforce_keys
end
