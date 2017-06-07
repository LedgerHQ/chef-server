%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% @author Marc Paradise <marc@chef.io>
%% Copyright 2017 Chef Software, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

%% Given:
%% % (spaces and newlines added for readability.  Each name[type]:val pair is space-separated.)
%% Input = <<"table public.clients: INSERT: id[character varying]:'da11fd5c59ad7cd575c4d53f6836168a'
%%                                          org_id[character]:'b22a18ce74e549b0ccb7da11fd5c59ad'
%%                                          authz_id[character]:'c3250a4fc08c482076abbaf6ed0b0ead'
%%                                          name[text]:'pedant_admin_client_api_23519'
%%                                          public_key[text]:'...snip...' ...
%%                                          validator[boolean]:false
%%                                          last_updated_by[character]:'f1cd13cb541436c290c2b4eb3685f6c2'
%%                                          created_at[timestamp without time zone]:'2017-06-05 18:06:47'
%%                                          updated_at[timestamp without time zone]:'2017-06-05 18:06:47'
%%                                          pubkey_version[smallint]:0
%%                                          admin[boolean]:false">>,
%%
%% migrator_decode:decode(Input) yields:
%%
%% { <<"clients">>, <<"INSERT">>, [ {<<"id">>, <<"da11fd5c59ad7cd575c4d53f6836168a">>},
%%                                  {<<"org_id">>, <<"b22a18ce74e549b0ccb7da11fd5c59ad">>},
%%                                  {<<"authz_id">>, <<"c3250a4fc08c482076abbaf6ed0b0ead">>},
%%                                  {<<"public_key">> <<"...snip...">>},
%%                                  {<<"validator">>, <<"false">>},
%%                                  {<<"last_updated_by">>, <<"f1cd13cb541436c290c2b4eb3685f6c2">>},
%%                                  {<<"created_at">>,<<"2017-06-05 18:06:47">>},
%%                                  {<<"updated_at">>,<<"2017-06-05 18:06:47">>},
%%                                  {<<"pubkey_version">>,0},
%%                                  {<<"admin">>,false} ] }
%%
%% All fields and values are binary, making them suitable for direct use in sql
%% queries. This works for now, but I could see a path that uses epgsql_binary
%% to manage conversion to correct data type as part of the decode process.
%% This may lead us to a place that lets us ship "{statement_name, [ARGS]}"
%% to the processor for it to execute via existing sqerl/prepared statement
%% without having to send over the complete statement.
%%
%% NOTE: So far, it seems that UPDATE/DELETE statements all arrive with the key field(s) first
%%       in the order.  Not fully verified in the test_decoder source.
-module(migrator_decode).

-export([decode/1]).

decode(Record) ->
  do_decode(Record).

do_decode(<<"BEGIN ", TXID/binary>>) ->
  {tx_start, TXID};
do_decode(<<"COMMIT ",TXID/binary>>) ->
  {tx_end, TXID};
do_decode(<<"table public.", Rest/binary>>) ->
  decode_transaction(Rest);
do_decode(<<"table ", _Rest/binary>>) ->
  % No sqitch or other schema support yet
  {error, unexpected_schema};
do_decode(_Other) ->
  % Not doing sequences or other object types yet either.
  {error, unknown_record}.

decode_transaction(Raw) ->
  {Table, Operation, Rest} = extract_op_elements(Raw),
  case processable(Rest) of
    true ->
      Fields = extract_fields(Rest, []),
      {Table, Operation, Fields};
    false ->
      {Table, Operation, noop}
  end.

extract_op_elements(Data) ->
  % Data = clients: INSERT: id[character varying]:'$VALUE'
  [Table, Rest0]  = binary:split(Data, <<": ">>),     % clients, INSERT: id[character varying]:'$VALUE'
  [Operation, Rest1] = binary:split(Rest0, <<": ">>), % INSERT, id[character varying]:'$VALUE'
  {Table, Operation, Rest1}.

  % This seems to happen for (maybe) some trigger-based deletes - I think in this cae
  % we have hit a cleanup path, because the same TX is used for a group of changes:
  % When it happens, it's the only field , in the form:
  % <<"table public.cookbook_artifact_version_checksums: DELETE: (no-tuple-data)">>},
  % <<"table public.checksums: DELETE: org_id[character]:'b22a18ce74e549b0ccb7da11fd5c59ad' checksum[character]:'268750691044b4fbab541d0edb2e0d7b'">>},
  % <<"table public.cookbook_artifacts: DELETE: id[integer]:17">>},
  % <<"table public.cookbook_artifact_versions: DELETE: id[bigint]:22">>},
processable(<<"(no-tuple-data)">>)  ->
  false;
processable(_) ->
  true.

extract_fields(<<>>, Acc) ->
  Acc;
extract_fields(TxData, Acc) ->
  % Data = id[character varying]:'$VALUE' something_else[....
  % enable this when we fail to match as expected
  % and you want to see where it left off:
  %io:fwrite("In: ~p~n", [TxData]),
  [Field, Rest0] = binary:split(TxData, <<"[">>),
  % We are not currently using type data when reconstituting these queries.
  [_Type, Rest1] = binary:split(Rest0, <<"]:">>),
  {Value, Rest3} = case Rest1 of
                       <<"'",Rest2/binary>> ->
                           {ok, Pos, R} = find_quoted_value_end(Rest2, 0),
                           V = binary:part(Rest1, 1, Pos),
                           {V, R};
                       Rest2 ->
                           % This is unquoted, so we're looking for a space only.
                           {ok, Pos, R} = find_value_end(Rest2, 0),
                           V = binary:part(Rest1, 0, Pos),
                           {V, R}
                   end,

  extract_fields(Rest3, [ { Field, Value} | Acc]).


find_value_end(<<>>, Pos) ->
  {ok, Pos, <<>>};
find_value_end(<<" ",Rest/binary>>, Pos) ->
  {ok, Pos, Rest};
find_value_end(<<_:1/binary, Rest/binary>>, Pos) ->
  find_value_end(Rest, Pos + 1).

% We wil need two paths here. Instead of worrying about the
% mapping of types -> quoted/not, we will look for the
% field separator of :.  If the next char is ', we epxect a matching close;
% otherwise we will look only for space.
% There are probably better ways, but this works for now:
% First exclude escaped apostrophes
find_quoted_value_end(<<"\\'",Rest/binary>>, Pos) ->
  find_quoted_value_end(Rest, Pos + 2);
find_quoted_value_end(<<"'">>, Pos) ->
  % ' at the end of the line is also an end marker
  {ok, Pos, <<>>};
find_quoted_value_end(<<"' ",Rest/binary>>, Pos) ->
  {ok, Pos, Rest};
find_quoted_value_end(<<>>, Pos) ->
  {error, {expected_field_end, Pos}};
find_quoted_value_end(<<_:1/binary, Rest/binary>>, Pos) ->
  find_quoted_value_end(Rest, Pos + 1).

