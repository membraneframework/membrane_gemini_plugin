defmodule Membrane.Gemini.Bin do
  @moduledoc """
  A Membrane Bin for integrating with Google's Gemini Live API.

  This bin provides a wrapper around the Gemini endpoint, accepting both audio and text
  inputs and producing audio output from the LLM.
  """

  use Membrane.Bin

  alias Membrane.RawAudio

  def_options mode: [
                spec: :continuous | :discrete,
                description:
                  "Whether the element should output audio as a continuous stream, intertwining the response audio with silence, or just the response audio buffers.
                  The first option is ideal for straightforward LLM integrations that don't require additional audio processing. The second is better if one wants more fine-grained control without needing VAD mechanisms.",
                default: :continuous
              ],
              config: [
                spec: Membrane.Gemini.Config.t(),
                description:
                  "Used to configure the `gemini_ex` GenServer managing the Live API session. For more details, see `Membrane.Gemini.Config`.",
                default: %Membrane.Gemini.Config{}
              ]

  def_input_pad :in_audio,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}

  def_input_pad :in_text,
    accepted_format: %Membrane.RemoteStream{type: :bytestream}

  def_output_pad :output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}

  @impl true
  def handle_init(_ctx, %{mode: mode, config: config} = _opts) do
    maybe_continuous_processing =
      if mode == :continuous do
        fn child_spec ->
          child_spec
          |> child(:queue, Membrane.Gemini.Queue)
          # Options used to enforce synchronous demands from the realtimer to Gemini
          |> via_in(:input, target_queue_size: 1, min_demand_factor: 1)
          |> child(:realtimer, Membrane.Realtimer)
        end
      else
        &Function.identity/1
      end

    spec = [
      bin_input(:in_audio)
      |> via_in(:in_audio)
      |> child(:gemini, %Membrane.Gemini.Endpoint{config: config})
      |> maybe_continuous_processing.()
      |> bin_output(:output),
      bin_input(:in_text)
      |> via_in(:in_text)
      |> get_child(:gemini)
    ]

    {[spec: spec], %{}}
  end

  @impl true
  def handle_parent_notification(:reset_session, _ctx, state),
    do: {[notify_child: {:gemini, :reset_session}], state}
end
