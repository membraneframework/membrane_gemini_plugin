defmodule Membrane.Gemini.Endpoint do
  @moduledoc false
  # This module is internally used by Membrane.Gemini.Bin

  use Membrane.Endpoint

  alias Membrane.RawAudio

  def_input_pad(:audio_input,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 16_000}
  )

  def_input_pad(:text_input,
    accepted_format: %Membrane.RemoteStream{type: :bytestream}
  )

  def_output_pad(:output,
    accepted_format: %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000},
    flow_control: :push
  )

  def_options(
    config: [
      spec: Membrane.Gemini.Config.t(),
      description:
        "See option description of `Membrane.Gemini.Bin` or the moduledoc of `Membrane.Gemini.Config`"
    ]
  )

  defmodule State do
    @type t :: %__MODULE__{
            status: :standby | :text_sent | :receiving | :eos,
            session_config: Membrane.Gemini.Config.t(),
            session_pid: pid(),
            in_audio_eos_received?: boolean(),
            in_text_eos_received?: boolean()
          }

    @enforce_keys [
      :session_config,
      :session_pid
    ]

    defstruct @enforce_keys ++
                [
                  status: :standby,
                  in_audio_eos_received?: false,
                  in_text_eos_received?: false
                ]
  end

  @impl true
  def handle_init(_ctx, %{config: config} = _opts) do
    session_pid = create_session(config)
    {[], %State{session_config: config, session_pid: session_pid}}
  end

  @impl true
  def handle_setup(_ctx, %State{session_pid: session_pid} = state) do
    case Gemini.Live.Session.connect(session_pid) do
      :ok -> :ok
      {:error, error} -> raise "Failed to start Gemini Live API session, error: #{inspect(error)}"
    end

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[
       stream_format:
         {:output, %RawAudio{sample_format: :s16le, channels: 1, sample_rate: 24_000}}
     ], state}
  end

  @impl true
  def handle_buffer(
        :audio_input,
        %Membrane.Buffer{payload: payload},
        _ctx,
        %State{session_pid: session_pid} = state
      ) do
    case Gemini.Live.Session.send_realtime_input(session_pid,
           audio: Gemini.Live.Audio.create_input_blob(payload)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Membrane.Logger.warning("sending audio payload failed: #{inspect(reason)}")
    end

    {[], state}
  end

  def handle_buffer(
        :text_input,
        %Membrane.Buffer{payload: payload},
        _ctx,
        %State{session_pid: session_pid} = state
      ) do
    case Gemini.Live.Session.send_realtime_input(session_pid, text: payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Membrane.Logger.warning("sending text payload failed: #{inspect(reason)}")
    end

    {[], %{state | status: :text_sent}}
  end

  @impl true
  def handle_info({:on_message, msg}, _ctx, %State{status: :eos} = state) do
    Membrane.Logger.info("Message received after element went into EOS status: #{inspect(msg)}")
    {[], state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{model_turn: %{parts: parts}}
         }},
        _ctx,
        %State{} = state
      )
      when is_list(parts) do
    mime_type = Gemini.Live.Audio.output_mime_type()

    # Note: `parts` seems to always be a singleton,
    # and the thinking prompt and audio come in through different invocations
    # Either way, we process the response as if `parts` could contain more than one element.
    actions =
      parts
      |> Enum.map(fn
        %{inline_data: %{"data" => data, "mimeType" => ^mime_type}} ->
          {:buffer, {:output, %Membrane.Buffer{payload: Base.decode64!(data)}}}

        %{text: text} ->
          {:event, {:output, %Membrane.Gemini.Events.Thinking{text: text}}}

        other ->
          Membrane.Logger.warning("Unrecognised response part received: #{inspect(other)}")
          nil
      end)
      |> Enum.reject(&Kernel.is_nil/1)

    if state.status == :receiving do
      {actions, state}
    else
      actions = [{:event, {:output, %Membrane.Gemini.Events.ResponseStart{}}} | actions]
      {actions, %{state | status: :receiving}}
    end
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           setup_complete: %Gemini.Types.Live.SetupComplete{session_id: id}
         }},
        _ctx,
        state
      ) do
    Membrane.Logger.debug("Gemini setup complete, session id: #{inspect(id)}")
    {[], state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{generation_complete: true}
         }},
        _ctx,
        %State{} = state
      ) do
    Membrane.Logger.debug("Received generation_complete: true")

    {maybe_eos_action, state} = maybe_eos(%{state | status: :standby})

    {[event: {:output, %Membrane.Gemini.Events.ResponseEnd{interrupted?: false}}] ++
       maybe_eos_action, state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{turn_complete: true},
           usage_metadata: %Gemini.Types.Live.UsageMetadata{} = usage_metadata
         }},
        _ctx,
        state
      ) do
    Membrane.Logger.debug("Turn metadata received: #{inspect(usage_metadata)}")
    Membrane.Logger.debug("Received turn_complete: true")
    {[], state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{
             input_transcription: %Gemini.Types.Live.Transcription{text: text}
           }
         }},
        _ctx,
        state
      ) do
    {[event: {:output, %Membrane.Gemini.Events.Transcript{text: text, direction: :input}}], state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{
             output_transcription: %Gemini.Types.Live.Transcription{text: text}
           }
         }},
        _ctx,
        %State{status: status} = state
      ) do
    transcript_action =
      {:event, {:output, %Membrane.Gemini.Events.Transcript{text: text, direction: :output}}}

    if status == :receiving do
      {[transcript_action], state}
    else
      start_response_action = {:event, {:output, %Membrane.Gemini.Events.ResponseStart{}}}

      {[start_response_action, transcript_action], %{state | status: :receiving}}
    end
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           server_content: %Gemini.Types.Live.ServerContent{
             interrupted: true
           }
         }},
        _ctx,
        %State{} = state
      ) do
    Membrane.Logger.debug("Interruption detected")

    {maybe_eos_action, state} = maybe_eos(%{state | status: :standby})

    {[event: {:output, %Membrane.Gemini.Events.ResponseEnd{interrupted?: true}}] ++
       maybe_eos_action, state}
  end

  def handle_info(
        {:on_message,
         %Gemini.Types.Live.ServerMessage{
           go_away: %Gemini.Types.Live.GoAway{time_left: time_left}
         }},
        _ctx,
        state
      ) do
    Membrane.Logger.debug("go_away received, time left: #{inspect(time_left)}")
    {[], state}
  end

  def handle_info({:on_message, msg}, _ctx, state) do
    Membrane.Logger.warning("Unrecognised message received by session: #{inspect(msg)}")
    {[], state}
  end

  def handle_info({:on_error, msg}, _ctx, state) do
    Membrane.Logger.error("Unhandled error received by session: #{inspect(msg)}")
    {[], state}
  end

  def handle_info(
        {:on_go_away, go_away_message},
        _ctx,
        %State{session_pid: session_pid, session_config: config, status: status} = state
      ) do
    if status == :receiving do
      Membrane.Logger.warning("Unexpected go_away received while receiving model response")
    end

    resume_handle =
      case go_away_message do
        %{handle: resume_handle, time_left_ms: _time_left_ms} ->
          Membrane.Logger.debug(
            "go_away received, restarting session using resume handle: #{inspect(resume_handle)}"
          )

          resume_handle

        %{time_left_ms: time_left_ms} ->
          Membrane.Logger.info("""
          go_away received without a resume handle, time left: #{inspect(time_left_ms)}
          The Gemini session will be restarted without previous context.
          """)

          nil

        other ->
          Membrane.Logger.warning("""
          Received go_away with unexpected message structure: #{inspect(other)}
          The Gemini session will be restarted without previous context.
          """)

          nil
      end

    new_session_pid = restart_session(session_pid, %{config | resume_handle: resume_handle})
    {[], %{state | status: :standby, session_pid: new_session_pid}}
  end

  def handle_info(message, _ctx, state) do
    Membrane.Logger.warning("Unrecognised message received by endpoint: #{inspect(message)}")
    {[], state}
  end

  @impl true
  def handle_parent_notification(
        :reset_session,
        _ctx,
        %State{
          status: status,
          session_pid: session_pid,
          session_config: config
        } = state
      ) do
    new_session_pid = restart_session(session_pid, %{config | resume_handle: nil})

    state = %{state | status: :standby, session_pid: new_session_pid}

    if status == :receiving do
      {maybe_eos_action, state} = maybe_eos(state)

      {[event: {:output, %Membrane.Gemini.Events.ResponseEnd{interrupted?: true}}] ++
         maybe_eos_action, state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_end_of_stream(:audio_input, _ctx, %State{session_pid: session_pid} = state) do
    # Flushes cached audio
    case Gemini.Live.Session.send_realtime_input(session_pid, audio_stream_end: true) do
      :ok -> :ok
      {:error, reason} -> Membrane.Logger.warning("Audio cache flush failed: #{inspect(reason)}")
    end

    maybe_eos(%{state | in_audio_eos_received?: true})
  end

  def handle_end_of_stream(:text_input, _ctx, state) do
    maybe_eos(%{state | in_text_eos_received?: true})
  end

  @spec create_session(config :: Membrane.Gemini.Config.t()) :: pid()
  def create_session(%Membrane.Gemini.Config{} = config) do
    Membrane.Logger.debug("Creating new session with config: #{inspect(config)}")
    filter_pid = self()

    # NOTE: A sender for `:on_transcription` is unnecessary since we also receive the transcripts
    # NOTE: as regular `server_content` messages.
    # NOTE: Same with `:on_session_resumption` - it passes the resume handle as an argument,
    # NOTE: but so does :on_go_away, which is also the only place where we explicitly need it.
    gemini_callbacks =
      [
        :on_message,
        :on_error,
        :on_go_away,

        # DEBUG
        :on_close
      ]
      |> Enum.map(fn callback_atom ->
        {
          callback_atom,
          &send(filter_pid, {callback_atom, &1})
        }
      end)

    config_opts =
      config
      |> Map.delete(:extra_opts)
      |> Map.from_struct()
      |> Keyword.new()

    gemini_opts =
      gemini_callbacks ++ config_opts ++ config.extra_opts

    {:ok, session_pid} =
      Gemini.Live.Session.start_link(gemini_opts)

    session_pid
  end

  @spec restart_session(
          session_pid :: pid(),
          config :: Membrane.Gemini.Config.t()
        ) :: pid()
  defp restart_session(session_pid, config) do
    Gemini.Live.Session.close(session_pid)
    new_session_pid = create_session(config)

    case Gemini.Live.Session.connect(new_session_pid) do
      :ok -> :ok
      {:error, error} -> raise "Failed to connect to Gemini Live API, error: #{inspect(error)}"
    end

    new_session_pid
  end

  @spec maybe_eos(state :: State.t()) ::
          {list(Membrane.Element.Action.end_of_stream()), State.t()}
  defp maybe_eos(
         %State{
           status: :standby,
           in_audio_eos_received?: true,
           in_text_eos_received?: true,
           session_pid: pid
         } = state
       ) do
    Gemini.Live.Session.close(pid)
    {[end_of_stream: :output], %{state | status: :eos}}
  end

  defp maybe_eos(state), do: {[], state}
end
