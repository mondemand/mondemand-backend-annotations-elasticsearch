-module (mondemand_backend_annotations_elasticsearch).

-behaviour (supervisor).
-behaviour (mondemand_server_backend).
-behaviour (mondemand_backend_worker).

%% mondemand_backend_worker callbacks
-export ([ create/1,
           connected/1,
           connect/1,
           send/2,
           destroy/1 ]).

%% mondemand_server_backend callbacks
-export ([ start_link/1,
           process/1,
           required_apps/0,
           type/0
         ]).

%% supervisor callbacks
-export ([ init/1 ]).

-define (POOL, md_ann_es_pool).
-define (MILLISECOND_CHECK, 10000000000).
-define (MILLISECOND_CORRECTION, 1000000000).
-define (MEGASECOND_ADJUST, 1000000).
-define (MILLISECOND_ADJUST, 1000).
-record (state, { annotation_labels, create_url, update_url, timeout }).

%%====================================================================
%% mondemand_server_backend callbacks
%%====================================================================
start_link (Config) ->
  supervisor:start_link ( { local, ?MODULE }, ?MODULE, [Config]).

process (Event) ->
  mondemand_backend_worker_pool_sup:process (?POOL, Event).

required_apps () ->
  [ crypto, public_key, ssl, lhttpc, lwes, mondemand ].

type () ->
  supervisor.

%%====================================================================
%% supervisor callbacks
%%====================================================================
init ([Config]) ->
  Number = proplists:get_value (number, Config, erlang:system_info(schedulers)), %Was 16

  { ok,
    {
      {one_for_one, 10, 10},
      [
        { ?POOL,
          { mondemand_backend_worker_pool_sup, start_link,
            [ ?POOL,
              mondemand_backend_worker,
              Number,
              ?MODULE ]
          },
          permanent,
          2000,
          supervisor,
          [ ]
        }
      ]
    }
  }.

%%====================================================================
%% mondemand_backend_worker callbacks
%%====================================================================
create (Config) ->
  AnnotationLabels = proplists:get_value (annotation_labels, Config),
  CreateUrl = proplists:get_value (create_url, Config),
  Timeout = proplists:get_value (timeout, Config),
  UpdateUrl = proplists:get_value (update_url, Config),
  {ok, #state { create_url = CreateUrl, update_url = UpdateUrl, timeout = Timeout,
                annotation_labels = AnnotationLabels
              }}.

connected (#state { create_url = undefined, update_url = undefined }) -> false;
connected (_) -> true.

connect (State) ->
  {ok, State}.

send (State = #state {annotation_labels = AnnotationLabels, create_url = Create_Url,
                      update_url = Update_Url, timeout = Timeout}, Event) ->
  Annotation = get_annotation(Event),
  Url = select_url(Annotation, Create_Url, Update_Url),
  case catch lhttpc:request
         (Url, "POST",[], format_annotation(Annotation, AnnotationLabels), Timeout, [{max_connections, 256}])
  of
    {ok, {{204,_},_,_}} ->
      { ok, State };
    E ->
      error_logger:error_msg ("elasticsearch responded with ~p",[E]),
      { error, State }
  end.

destroy (_) ->
  ok.

%%======================
%% Internal functions
%%======================
get_annotation (Event) ->
  AnnotationMsg = mondemand_event:msg (Event),
  [ {timestamp, mondemand_annotationmsg:timestamp(AnnotationMsg) },
    {description, mondemand_annotationmsg:description(AnnotationMsg) },
    {title, mondemand_annotationmsg:text(AnnotationMsg)},
    {tags,
      iolist_to_binary (mondemand_server_util:join([ T || T <- mondemand_annotationmsg:tags(AnnotationMsg), T =/= []],
                                                   ",")) },
    {id, mondemand_annotationmsg:id(AnnotationMsg)} ].

select_url ( AnnotationList, Create_Url, Update_Url) ->
  case proplists:get_value(id, AnnotationList) of
    ID when ID /= <<>> -> lists:flatten(io_lib:format(Update_Url, [ID]));
    _ -> Create_Url
  end.

format_annotation ( Annotation, Labels ) ->
  InterAnnotation = [ { proplists:get_value(Name, Labels, Name), Value }
                      || { Name, Value } <- Annotation,
                         is_integer(proplists:get_value( Name, Annotation) ) == false,
                         proplists:get_value( Name, Annotation) =/= <<>>
                    ],
  AnnoTime = to_iso8601(proplists:get_value( timestamp, Annotation)),
  case proplists:get_value(id, Annotation) of
    ID when ID =/= <<>> ->
      FormattedAnnotation = [{"doc", [{ proplists:get_value( timestamp, Labels),
                                        AnnoTime }
                                      | InterAnnotation ]}];
    _ -> FormattedAnnotation = [{ proplists:get_value( timestamp, Labels),
                                  AnnoTime }
                                | InterAnnotation ]
  end,
  mochijson2:encode({struct, FormattedAnnotation}).

%% to_iso8601() ->
%%   {Mega, Sec, Micro} = os:timestamp(),
%%   to_iso8601( (Mega*?MEGASECOND_ADJUST + Sec)*?MILLISECOND_ADJUST + round(Micro div ?MILLISECOND_ADJUST) ).
to_iso8601 ( MilliTime ) ->
  AdjustedMilliTime =
    case MilliTime of
      MilliTime when MilliTime =< ?MILLISECOND_CHECK -> %Excluding milliseconds
        MilliTime * ?MILLISECOND_ADJUST;
      MilliTime when MilliTime >= ?MILLISECOND_CHECK -> %Already has milliseconds
        MilliTime
    end,
  {{Year, Month, Day}, {Hour, Minute, Second}}
    = calendar:now_to_datetime({AdjustedMilliTime div ?MILLISECOND_CORRECTION,
                                (AdjustedMilliTime rem ?MILLISECOND_CORRECTION) div ?MILLISECOND_ADJUST,
                                AdjustedMilliTime rem ?MILLISECOND_ADJUST}),
  Milliseconds = AdjustedMilliTime rem ?MILLISECOND_ADJUST,
  list_to_binary(io_lib:format("~4..0w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0w.~3..0wZ",
                               [Year, Month, Day, Hour, Minute, Second, Milliseconds])).





%-=====================================================================-
%-                            Test Functions                           -
%-=====================================================================-
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

annotation_test_ () ->
  [
   {"create test",
    fun () ->
        GottenState = create([{annotation_labels, [{"test", "value"}]},
                              {create_url, "testcreate"},
                              {update_url, "testupdate"},
                              {timeout, 42}]),
        ExpectedState = {ok,{state,[{"test","value"}],"testcreate","testupdate",42}},
        ?assertEqual(ExpectedState, GottenState)
    end
   },
   {"get annotation test",
    fun () ->
        AnnoResp = get_annotation(mondemand_event:new({127,0,0,1}, 2000, 5, <<"MonDemand::AnnotationMsg">>,
                                                      mondemand_annotationmsg:new(42, 1000000000,
                                                              "desc", "title",
                                                              ["tag1", "tag2"],
                                                              []))),
        Expected = [{timestamp, 1000000000}, {description, "desc"},
                    {title, "title"}, {tags, <<"tag1,tag2">>}, {id, 42}],
        ?assertEqual(Expected, AnnoResp),
        AnnoResp2 = get_annotation(mondemand_event:new({127,0,0,1}, 2000, 5, <<"MonDemand::AnnotationMsg">>,
                                                       mondemand_annotationmsg:new(43, 1000000000,
                                                                                   "desc", "title",
                                                                                   [],
                                                                                   []))),
        Expected2 = [{timestamp, 1000000000}, {description, "desc"},
                    {title, "title"}, {tags, <<>>}, {id, 43}],
        ?assertEqual(Expected2, AnnoResp2)
    end
   },
   {"select_url_test",
    fun () ->
        URL = select_url([{id, 42}], "testcreate", "testupdate~p"),
        ExpectedURL = "testupdate42",
        ?assertEqual(ExpectedURL, URL),
        URL2 = select_url([{id, <<>>}], "testcreate", "testupdate~p"),
        ExpectedURL2 = "testcreate",
        ?assertEqual(ExpectedURL2, URL2)
    end
   },
   {"test formatting annotation to json",
    fun () ->
        AnnotationList = [{bob, "test"}, {"foo","bar"}, {timestamp, 1000000000}, {"ignore", 42}],
        LabelList = [{bob, "Robert"}, {timestamp, "TimeStamp"}],
        AnnoJSON = format_annotation(AnnotationList, LabelList),
        Comparitor = mochijson2:encode({struct, [{"doc", [{"TimeStamp", <<"2001-09-09T01:46:40.000Z">>},
                                                          {"Robert", "test"},
                                                          {"foo", "bar"}
                                                         ]}]}),
        ?assertEqual(Comparitor, AnnoJSON),
        AnnotationList2 = [{bob, "test"}, {id, "A123"}, {"foo","bar"}, {timestamp, 1000000000}, {"ignore", 42}],
        LabelList2 = [{bob, "Robert"}, {timestamp, "TimeStamp"}],
        AnnoJSON2 = format_annotation(AnnotationList2, LabelList2),
        Comparitor2 = mochijson2:encode({struct, [{"doc", [{"TimeStamp", <<"2001-09-09T01:46:40.000Z">>},
                                                           {"Robert", "test"},
                                                           {"id", "A123"},
                                                           {"foo", "bar"}
                                                          ]}]}),
        ?assertEqual(Comparitor2, AnnoJSON2)
    end
   },
   {"test iso8601 string construction",
     fun () ->
         {Mega, Sec, Micro} = {1234,567890,777777},
         ISO = to_iso8601((Mega*?MEGASECOND_ADJUST + Sec)*?MILLISECOND_ADJUST + round(Micro div ?MILLISECOND_ADJUST)),
         ?assertEqual(<<"2009-02-13T23:31:30.777Z">>, ISO),
         ISO2 = to_iso8601((Mega*?MEGASECOND_ADJUST + Sec)),
         ?assertEqual(<<"2009-02-13T23:31:30.000Z">>, ISO2)
     end
   }
  ].

-endif.
