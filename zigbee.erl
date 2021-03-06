%%%-------------------------------------------------------------------
%%% File    : zigbee.erl
%%% Author  : Dan Willemsen <dan@csh.rit.edu>
%%% Purpose : Zigbee API Interface
%%%
%%% Copyright (C) 2008-2009 Dan Willemsen
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%                         
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------

-module (zigbee).
-behaviour (gen_server).

-export ([start/0, start/1]).
-export ([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export ([at_command/1, at_command/2, remote_at_command/2, remote_at_command/3]).

-record (state, {serial, pendingdata = <<>>, calltable, curframeid = 0}).

start() ->
  start("/dev/tty.usbserial-A6005vO3").

start(File) ->
  gen_server:start({local, ?MODULE}, ?MODULE, {File}, []).

init({File}) ->
  process_flag(trap_exit, true),
  Serial = serial:start([{speed, 9600},{open, File}]),
  CallTable = ets:new(calltable, []),
  {ok, #state{serial=Serial,calltable=CallTable}}.

handle_call({at_command, [A,T], Data}, From, State) ->
  {FrameID, NewState} = next_frame_id(State),
  ets:insert(State#state.calltable, {FrameID, From}),
  write_packet(<<16#08, FrameID:8, A, T, Data/binary>>, State),
  {noreply, NewState};
handle_call({remote_at_command, NetAddr, [A,T], Data}, From, State) ->
  {FrameID, NewState} = next_frame_id(State),
  ets:insert(State#state.calltable, {FrameID, From}),
  DestAddr = 16#FFFF,
  write_packet(<<16#17, FrameID:8, DestAddr:64, NetAddr:16, 2:8, A, T, Data/binary>>, State),
  {noreply, NewState};
handle_call(_Request, _From, State) ->
  {reply, {error, badcall}, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

handle_info({data, Bytes}, State) ->
  PrevPendingData = State#state.pendingdata,
  case interpret_packet(<<PrevPendingData/binary, Bytes/binary>>, State) of
    {found, Rest} ->
      handle_info({data, <<>>}, State#state{pendingdata = Rest});
    {not_found, Rest} ->
      {noreply, State#state{pendingdata = Rest}}
  end;
handle_info({'EXIT', Pid, Reason}, State) when State#state.serial =:= Pid ->
  {stop, Reason, State};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

next_frame_id(State) when State#state.curframeid == 255 ->
  {1, State#state{curframeid=1}};
next_frame_id(State) ->
  {State#state.curframeid + 1, State#state{curframeid = State#state.curframeid + 1}}.

write_packet(Contents, State) when is_binary(Contents) ->
  Size = size(Contents),
  Checksum = calc_checksum(Contents),
  State#state.serial ! {send, <<16#7e, Size:16, Contents/binary, Checksum:8>>}.

calc_checksum(Checksum, Rest) when is_binary(Rest), size(Rest) == 0 ->
  Checksum;
calc_checksum(<<Checksum:8>>, <<A:8/unsigned-little-integer,Rest/binary>>) ->
  Val = Checksum + A,
  calc_checksum(<<Val:8>>, Rest).

calc_checksum(Bin) ->
  <<Res:8>> = calc_checksum(<<0>>, Bin),
  16#ff - Res.

interpret_packet(Bin, _State) when size(Bin) == 0 ->
  {not_found, <<>>};
interpret_packet(<<16#7e, Length:16, Contents:Length/binary, Checksum:8, Rest/binary>>, State) ->
  case calc_checksum(Contents) of
    Checksum ->
      interpret_api_packet(Contents, State);
    Else ->
      io:format("Got Packet with invalid checksum! (~w != ~w)~n", [Else, Checksum])
  end,
  {found, Rest};
interpret_packet(Unknown, _State) ->
  {not_found, Unknown}.

interpret_api_packet(Contents, State) ->
  {Type, Details} = decode_packet(Contents),
  case Type of
    _ when Type =:= at_command_response; Type =:= remote_at_command_response ->
      io:format("Got ~w packet: ~w~n", [Type, Details]),
      Dict = dict:from_list(Details),
      FrameID = dict:fetch(frameid, Dict),
      {FrameID, ResponseTo} = hd(ets:lookup(State#state.calltable, FrameID)),
      Response = case dict:fetch(status, Dict) of
        ok ->
          {ok, dict:fetch(data, Dict)};
        {error, Reason} ->
          {error, Reason};
        unknown ->
          {unknown, dict:fetch(data, Dict)}
      end,
      gen_server:reply(ResponseTo, Response);
    rx_packet ->
      io:format("Got serial packet: ~p~n", [Details]);
    _Else ->
      io:format("Got ~w packet: ~w~n", [Type, Details])
  end.

decode_packet(<<16#8a, Status:8>>) ->
  {modem_status, decode_packet_status(modem_status, Status)};
decode_packet(<<16#88, FrameID:8, Command1:8, Command2:8, Status:8, Data/binary>>) ->
  {at_command_response, [ {frameid, FrameID},
              {at_command, [Command1,Command2]},
              {status, decode_packet_status(at_command_response, Status)},
              {data, decode_at_command_response_data([Command1,Command2], Data)}]};
decode_packet(<<16#97, FrameID:8, RemoteAddr:64, NetAddr:16, Command1:8, Command2:8, Status:8, Data/binary>>) ->
  {remote_at_command_response, [  {frameid, FrameID},
                  {remoteaddr, RemoteAddr},
                  {netaddr, NetAddr},
                  {at_command, [Command1, Command2]},
                  {status, decode_packet_status(at_command_response, Status)},
                  {data, decode_at_command_response_data([Command1,Command2], Data)}]};
decode_packet(<<16#8b, _FrameID:8, _NetAddr:16, _RetryCount:8, _DeliveryStatus:8, _DiscoveryStatus:8>>) ->
  {transmit_status, []};
decode_packet(<<16#90, _Address:64, _NetAddr:16, _Options:8, Data/binary>>) ->
  {rx_packet, binary_to_list(Data)};
decode_packet(<<16#92, _Address:64, _NetAddr:16, _Options:8, _NumSamples:8, _DigitalChannelMask:16,
          _AnalogChannelMask:8, _DigitalSamples:16, _AnalogSamples/binary>>) ->
  {sample_rx, []};
decode_packet(<<16#95, _SenderAddr:64, _NetAddr:16, _Options:8, _SourceNetAddr:16, _SourceAddr:64, _:8, Data/binary>>) ->
  NodeIDLength = size(Data) - 9,
  <<NodeID:NodeIDLength/binary, 0:8, ParentNetAddr:16, DeviceType:8, SourceEvent:8, ProfileID:16,
    ManufacturerID:16>> = Data,
  {node_id, [{nodeid, NodeID},
             {parent, ParentNetAddr},
             {type, decode_device_type(DeviceType)},
             {event, decode_packet_status(source_event, SourceEvent)},
             {profile, ProfileID},
             {manufacturer, ManufacturerID}]};
% Unwrap RX Packet (Explicit RX) to normal RX Packet
decode_packet(<<16#91, SourceAddr:64, NetAddr:16, _SourceEndpoint:8, _DestEndpoint:8, 17:16,
                _ProfileID:16, Options:8, Data/binary>>) ->
  decode_packet(<<16#90, SourceAddr:64, NetAddr:16, Options:8, Data/binary>>);
% Unwrap Node ID Explicit RX Packet to normal Node ID Packet
decode_packet(<<16#91, SourceAddr:64, NetAddr:16, _SourceEndpoint:8, _DestEndpoint:8, 149:16,
                _ProfileID:16, Options:8, _:8, Data/binary>>) ->
  decode_packet(<<16#95, SourceAddr:64, NetAddr:16, Options:8, NetAddr:16, SourceAddr:64, 0:8, Data/binary>>);
decode_packet(<<16#91, SourceAddr:64, NetAddr:16, SourceEndpoint:8, DestEndpoint:8, ClusterID:16,
                ProfileID:16, Options:8, Data/binary>>) ->
  {explicit_rx, [ {sourceaddr, SourceAddr},
                  {netaddr, NetAddr},
                  {sourceendpoint, SourceEndpoint},
                  {destendpoint, DestEndpoint},
                  {cluster, ClusterID},
                  {profile, ProfileID},
                  {options, Options},
                  {data, Data}]};
decode_packet(<<PacketType:8, Rest/binary>>) ->
  {PacketType, Rest}.

decode_packet_status(at_command_response, 0) -> ok;
decode_packet_status(at_command_response, 1) -> {error, generic};
decode_packet_status(at_command_response, 2) -> {error, invalid_command};
decode_packet_status(at_command_response, 3) -> {error, invalid_parameter};
decode_packet_status(modem_status, 0) -> hardware_reset;
decode_packet_status(modem_status, 1) -> watchdog_timer_reset;
decode_packet_status(modem_status, 2) -> associated;
decode_packet_status(modem_status, 3) -> disassociated;
decode_packet_status(modem_status, 4) -> synchronization_lost;
decode_packet_status(modem_status, 5) -> coordinator_realignment;
decode_packet_status(modem_status, 6) -> coordinator_started;
decode_packet_status(source_event, 1) -> button;
decode_packet_status(source_event, 2) -> join;
decode_packet_status(source_event, 3) -> power_cycle;
decode_packet_status(_, _)            -> unknown.

decode_at_command_response_data("ND", Data) ->
  NodeIDLength = size(Data) - 19,
  <<NetAddr:16, Serial:64, NodeID:NodeIDLength/binary, 0:8, ParentNetAddr:16, DeviceType:8,
    Status:8, ProfileID:16, ManufacturerID: 16>> = Data,
  [{netaddr, NetAddr},
   {serial, Serial},
   {parent, ParentNetAddr},
   {nodeid, NodeID},
   {type, decode_device_type(DeviceType)},
   {status, Status},
   {profile, ProfileID},
   {manufacturer, ManufacturerID}];
decode_at_command_response_data("%V", <<Data:16>>) ->
  Data / 1024;
decode_at_command_response_data(short_num, <<Data:16>>) ->
  lists:nth(1, io_lib:format("~.16B", [Data]));
decode_at_command_response_data("VR", Data) -> decode_at_command_response_data(short_num, Data);
decode_at_command_response_data("HV", Data) -> decode_at_command_response_data(short_num, Data);
decode_at_command_response_data(_, Data) -> Data.

decode_device_type(0) -> coordinator;
decode_device_type(1) -> router;
decode_device_type(2) -> end_device.

%%% External API
at_command(AT) when is_list(AT), length(AT) =:= 2 ->
  at_command(AT, <<>>).

at_command(AT, Data) when is_list(AT), length(AT) =:= 2, is_binary(Data) ->
  gen_server:call(?MODULE, {at_command, AT, Data}).

remote_at_command(NetAddr, AT) when is_list(AT), length(AT) =:= 2 ->
  remote_at_command(NetAddr, AT, <<>>).

remote_at_command(NetAddr, AT, Data) when is_list(AT), length(AT) =:= 2, is_binary(Data) ->
  gen_server:call(?MODULE, {remote_at_command, NetAddr, AT, Data}).